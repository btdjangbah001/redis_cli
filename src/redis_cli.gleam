import gleam/bit_array
import gleam/bytes_builder
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glisten.{Packet}
import parser.{Array, BulkString, ErrorValue}
import cache.{type Cache}

const ping_response = "+PONG\r\n"
 
fn init_store() -> Cache {
  let assert Ok(cache) = cache.new()
  cache
  //read AOLF to reconstruct db in terms of restart
}

pub fn main() {
  let store = init_store()

  let assert Ok(_) =
    glisten.handler(fn(_conn) { #(Nil, None) }, fn(msg, state, conn) {
      let assert Packet(msg) = msg
      let message = clean_msg(msg)
      case string.lowercase(message) {
        "ping" -> {
          let assert Ok(_) =
            glisten.send(conn, bytes_builder.from_string(ping_response))
          actor.continue(state)
        }
        _ -> {
          let redisvalue = parser.decode(message)
          case redisvalue.0 {
            Array(Some(list)) -> {
              case list.reverse(list) {
                [BulkString(command_opt), BulkString(arg_opt)] -> {
                  case command_opt, arg_opt {
                    Some(command), Some(arg) ->
                      case string.lowercase(command) {
                        "echo" -> {
                          let assert Ok(_) =
                            glisten.send(
                              conn,
                              bytes_builder.from_string(parser.encode(BulkString(arg_opt), "")),
                            )
                          actor.continue(state)
                        }
                        "get" -> {
                          let value = cache.get(store, arg)
                          case value {
                            Ok(val) -> {
                              let assert Ok(_) =
                                glisten.send(
                                  conn,
                                  bytes_builder.from_string(parser.encode(val, "")), //must encode redis value now!
                                )
                              actor.continue(state)
                            }
                            Error(_) -> {
                              let assert Ok(_) =
                                glisten.send(
                                  conn,
                                  bytes_builder.from_string("(nil)"), //must encode redis value now!
                                )
                              actor.continue(state)
                            } 
                          }
                        }
                        _ -> {
                          let assert Ok(_) =
                            glisten.send(
                              conn,
                              bytes_builder.from_string(parser.encode(ErrorValue("ERR unknown command"), ""))
                            )
                          actor.continue(state)
                        }
                      }
                    Some(command), None ->
                      case string.lowercase(command) {
                        "echo" -> {
                          let assert Ok(_) =
                            glisten.send(
                              conn,
                              bytes_builder.from_string(parser.encode(ErrorValue("ERR (nil) argument to " <> command), ""),
                            ))
                          actor.continue(state)
                        }
                        _ -> {
                          let assert Ok(_) =
                            glisten.send(
                              conn,
                              bytes_builder.from_string(parser.encode(ErrorValue("ERR unknown command " <> command), "")),
                            )
                          actor.continue(state)
                        }
                      }
                    _, _ -> {
                      let assert Ok(_) =
                        glisten.send(
                          conn,
                          bytes_builder.from_string(parser.encode(ErrorValue("ERR unknown command"), "")),
                        )
                      actor.continue(state)
                    }
                  }
                }
                [BulkString(command_opt), BulkString(key_opt), BulkString(value_opt)] -> {
                  case command_opt, key_opt, value_opt {
                    Some(command), Some(key), Some(value) -> {
                      case string.lowercase(command) {
                        "set" -> {
                          cache.set(store, key, BulkString(Some(value)))
                          let assert Ok(_) =glisten.send(conn, bytes_builder.from_string(parser.encode(parser.SimpleString("OK"), ""),))
                          actor.continue(state)
                        }
                        _ -> {
                          let assert Ok(_) = glisten.send(
                              conn,
                              bytes_builder.from_string(parser.encode(ErrorValue("ERR unknown command " <> command), "")),
                            )
                          actor.continue(state)
                        }
                      }
                    }
                    None, _, _ -> {
                      let assert Ok(_) = glisten.send(conn, bytes_builder.from_string(parser.encode(ErrorValue("ERR command can't be (nil)"), "")),)
                      actor.continue(state)
                    }
                    _, None, _ -> {
                      let assert Ok(_) = glisten.send(conn, 
                      bytes_builder.from_string(parser.encode(ErrorValue("ERR unknown command"), "")),
                      )
                      actor.continue(state)
                    }
                    _, _, None -> {
                      let assert Ok(_) = glisten.send(conn, bytes_builder.from_string(parser.encode(ErrorValue("ERR unknown command"), "")),)
                      actor.continue(state)
                    }
                  }
                }
                _ -> {
                  let assert Ok(_) =
                    glisten.send(
                      conn,
                      bytes_builder.from_string(
                        "We matched more than 2 items in list",
                      ),
                    )
                  actor.continue(state)
                }
              }
            }
            ErrorValue(text) -> {
              let assert Ok(_) =
                glisten.send(conn, bytes_builder.from_string(text))
              actor.continue(state)
            }
            _ -> {
              let assert Ok(_) =
                glisten.send(conn, bytes_builder.from_string("Nothing worked"))
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
  |> result.unwrap("")
  |> string.trim
}

