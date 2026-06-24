#![allow(unused_results)]

use super::*;
use rusqlite::Connection;

fn open_memory() -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA foreign_keys = ON;",
    )
    .unwrap();
    conn
}

mod primitive;
