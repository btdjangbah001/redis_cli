import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import parser.{type RedisValue}

const timeout = 3000

pub type Store =
  Dict(String, RedisValue)

pub type Message {
  Get(Subject(Result(RedisValue, Nil)), String)
  Set(String, RedisValue)
  Delete(String)
}

pub type Cache =
  Subject(Message)

fn handle_commands(message: Message, store: Store) -> actor.Next(Message, Store) {
  case message {
    Set(key, value) -> {
      let store = dict.insert(store, key, value)
      actor.continue(store)
    }
    Get(client, key) -> {
      process.send(client, dict.get(store, key))
      actor.continue(store)
    }
    Delete(key) -> {
      let store = dict.delete(store, key)
      actor.continue(store)
    }
  }
}

pub fn new() -> Result(Cache, actor.StartError) {
  actor.start(dict.new(), handle_commands)
}

pub fn set(cache: Cache, key: String, value: RedisValue) -> Nil {
  process.send(cache, Set(key, value))
}

pub fn get(cache: Cache, key: String) -> Result(RedisValue, Nil) {
  actor.call(cache, Get(_, key), timeout)
}

pub fn delete(cache: Cache, key: String) -> Nil {
  process.send(cache, Delete(key))
}
