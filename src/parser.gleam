import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

fn encode_bulk_string(input: String) -> String {
  "$" <> int.to_string(string.length(input)) <> "\r\n" <> input <> "\r\n"
}

pub type RedisValue {
  SimpleString(String)
  BulkString(Option(String))
  Integer(Int)
  Array(Option(List(RedisValue)))
  ErrorValue(String)
}

type DecodeResult =
  #(RedisValue, String)

pub fn decode(input: String) -> DecodeResult {
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
    "+" <> rest -> decode_simple_string(rest)
    ":" <> rest -> decode_integer(rest)
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

fn decode_simple_string(input: String) -> DecodeResult {
  let parts = string.split_once(input, "\\r\\n")

  case parts {
    Ok(p) -> {
      let str = p.0
      case skip_separator(p.1) {
        Ok(inp) -> #(SimpleString(str), inp)
        Error(_) -> #(ErrorValue("Protocol error. Expected delimeter"), p.1)
      }
    }
    Error(_) -> #(ErrorValue("Protocol error. Expected a string"), input)
  }
}

fn decode_bulk_string(input: String, size: Int, acc: RedisValue) -> DecodeResult {
  case size {
    0 -> {
      case skip_separator(input) {
        Ok(inp) -> {
          #(acc, inp)
        }
        Error(_) -> #(ErrorValue("Protocol error. Expected delimeter"), input)
      }
    }
    -1 -> #(BulkString(None), input)
    _ -> {
      let acc = case string.first(input) {
        Ok(letter) ->
          case acc {
            BulkString(Some(data)) ->
              BulkString(Some(string.append(data, letter)))
            _ -> ErrorValue("Bulk string acc souldn't be anything else")
          }
        Error(_) -> ErrorValue("String length did not match")
      }
      decode_bulk_string(
        string.slice(input, 1, string.length(input)),
        size - 1,
        acc,
      )
    }
  }
}

fn decode_integer(inp: String) -> DecodeResult {
  let parts = string.split_once(inp, "\\r")

  case parts {
    Ok(p) -> {
      case int.parse(p.0) {
        Ok(num) -> {
          let rest = string.append("\\r", p.1)
          case skip_separator(rest) {
            Ok(inp) -> {
              #(Integer(num), inp)
            }
            Error(_) -> #(ErrorValue("Protocol error. Expected delimeter"), p.1)
          }
        }
        Error(_) -> #(ErrorValue("Expected a number\r\n"), inp)
      }
    }
    Error(_) -> #(ErrorValue("Protocol error\r\n"), inp)
  }
}

fn skip_separator(input: String) -> Result(String, Nil) {
  case input {
    "\\r\\n" <> rest -> Ok(rest)
    _ -> Error(Nil)
  }
}

pub fn encode(value: RedisValue, acc: String) -> String {
  case value {
    SimpleString(value) -> string.append(acc, ":" <> value <> "\r\n")
    BulkString(Some(value)) -> string.append(acc, encode_bulk_string(value))
    BulkString(None) -> string.append(acc, "$-1\r\n")
    Integer(value) -> string.append(acc, ":" <> int.to_string(value) <> "\r\n")
    Array(Some(value)) -> {
      case value {
        [] -> acc
        [head, ..tail] -> {
          let acc = encode(head, acc)
          encode(Array(Some(tail)), acc)
        }
      }
    }
    Array(None) -> string.append(acc, "*-1\r\n")
    ErrorValue(error) -> "-ERR " <> error
  }
}
