import gleam/bytes_builder
import gleam/erlang/process
import gleam/option.{None, type Option, Some}
import gleam/otp/actor
import glisten.{Packet}
import gleam/string
import gleam/bit_array
import gleam/result
import gleam/int

const ping_response = "+PONG\r\n"

pub fn main() {
  let assert Ok(_) =
    glisten.handler(fn(_conn) { #(Nil, None) }, fn(msg, state, conn) {
      let assert Packet(msg) = msg
      let message = clean_msg(msg)
      case string.lowercase(message)  {
        "ping" -> {
          let assert Ok(_) = glisten.send(conn, bytes_builder.from_string(ping_response))
          actor.continue(state)
        } 
        _ -> {
          let redisvalue = decode(message)
          case redisvalue.0 {
            Array(Some(list)) -> {
              case list {
                [command, arg] -> {
                  case command {
                    BulkString(Some(command)) -> {
                      case string.lowercase(command) {
                        "echo" -> {
                          case arg {
                            BulkString(Some(arg)) -> {
                              let assert Ok(_) = glisten.send(conn, bytes_builder.from_string(encode_bulk_string(arg)))
                              actor.continue(state)
                            }
                            _ -> {
                              let assert Ok(_) = glisten.send(conn, bytes_builder.from_string("Error happened in arg"))
                              actor.continue(state)
                            }
                          }
                        }
                         _ -> {
                          let assert Ok(_) = glisten.send(conn, bytes_builder.from_string("Command is not echo"))
                          actor.continue(state)
                         }
                      }
                    }
                    ErrorValue(text) -> {
                      let assert Ok(_) = glisten.send(conn, bytes_builder.from_string(text))
                      actor.continue(state)
                    } 
                    _ -> {
                      let assert Ok(_) = glisten.send(conn, bytes_builder.from_string("Command is not error value nor bulk string"))
                      actor.continue(state)
                    }
                  }
                }
                _ -> {
                  let assert Ok(_) = glisten.send(conn, bytes_builder.from_string("We matched more than 2 items in list"))
                  actor.continue(state)
                }
              }
            }
            ErrorValue(text) -> {
              let assert Ok(_) = glisten.send(conn, bytes_builder.from_string(text))
              actor.continue(state)
            }
            _ -> {
              let assert Ok(_) = glisten.send(conn, bytes_builder.from_string("Nothing worked"))
              actor.continue(state)
            }
          }
        }
      }
    })
    |> glisten.serve(6379)

  process.sleep_forever()
}

fn clean_msg(msg: BitArray) -> String {
  bit_array.to_string(msg) 
    |> result.unwrap(_, "")
    |> string.trim
}

fn encode_bulk_string(input: String) -> String {
  "$" <> int.to_string(string.length(input)) <> "\r\n" <> input <> "\r\n"
}


type RedisValue {
  BulkString(Option(String))
  Integer(Int)
  Array(Option(List(RedisValue)))
  ErrorValue(String)
}

type DecodeResult = #(RedisValue, String)

fn decode(input: String) -> DecodeResult {
  case input {
    "*" <> rest -> {
      let int_decode_result = decode_integer(rest)
      let redisvalue = int_decode_result.0
      let size_option = case redisvalue {
        Integer(num) -> Some(num)
        _ -> None
      }
      case size_option {
        Some(num) -> {
          let input = int_decode_result.1
          decode_array(input, num, Array(Some([])))
        }
        None -> #(redisvalue, input)
      }
    }
    "$" <> rest -> {
      let int_decode_result = decode_integer(rest)
      let redisvalue = int_decode_result.0
      let size_option = case redisvalue {
        Integer(num) -> Some(num)
        _ -> None
      }
      case size_option {
        Some(num) -> {
          let input = int_decode_result.1
          decode_bulk_string(input, num, BulkString(Some("")))
        }
        None -> #(redisvalue, input)
      }
    }
    _ -> #(ErrorValue("Error parsing, we don't support this type yet!"), input)
  }
}

fn decode_array(input: String, size: Int, acc: RedisValue) -> DecodeResult {
  case size {
    0 -> #(acc, input)
    -1 -> #(Array(None), input)
    _ -> {
      let value = decode(input)
      let acc = case acc {
        Array(Some(list)) -> Array(Some([value.0, ..list]))
        _ -> ErrorValue("Array acc souldn't be anything else")
      }
      decode_array(value.1, size - 1, acc)
    }
  }
}

fn decode_bulk_string(input: String, size: Int, acc: RedisValue) -> DecodeResult {
  case size {
    0 -> #(acc, input)
    -1 -> #(BulkString(None), input)
    _ -> {
      let acc = case string.first(input) {
        Ok(letter) -> case acc {
          BulkString(Some(data)) -> BulkString(Some(data <> letter))
          _ -> ErrorValue("Bulk string acc souldn't be anything else")
        }
        Error(_) -> ErrorValue("String length did not match")
      }
      decode_bulk_string(string.slice(input, 1, string.length(input)), size - 1, acc)
    }
  }
}

fn decode_integer(inp: String) -> DecodeResult {
  let parts = string.split_once(inp, "\\r")

  case parts {
    Ok(p) -> {
      let num = int.parse(p.0) |> result.unwrap(_, -1)
      let rest = string.append("\\r", p.1)
      #(Integer(num), rest)
    }
    Error(_) -> #(ErrorValue("Expected a number"), inp) 
  }
}