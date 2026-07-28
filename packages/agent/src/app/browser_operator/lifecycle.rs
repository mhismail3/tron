//! Native stdio bridge threads and Unix-socket cleanup ownership.

use super::*;

pub(super) fn spawn_native_stdin(sender: mpsc::Sender<NativeEvent>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        loop {
            let mut length = [0_u8; 4];
            if let Err(error) = stdin.read_exact(&mut length) {
                let _ = sender.blocking_send(NativeEvent::Disconnected(error.to_string()));
                break;
            }
            let length = u32::from_le_bytes(length) as usize;
            if length == 0 || length > MAX_NATIVE_RESPONSE_BYTES {
                let _ = sender.blocking_send(NativeEvent::Disconnected(
                    "native message is empty or oversized".to_owned(),
                ));
                break;
            }
            let mut bytes = vec![0_u8; length];
            if let Err(error) = stdin.read_exact(&mut bytes) {
                let _ = sender.blocking_send(NativeEvent::Disconnected(error.to_string()));
                break;
            }
            match serde_json::from_slice::<NativeInbound>(&bytes) {
                Ok(message) => {
                    if sender.blocking_send(NativeEvent::Message(message)).is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let _ = sender.blocking_send(NativeEvent::Disconnected(format!(
                        "invalid native message: {error}"
                    )));
                    break;
                }
            }
        }
    })
}

pub(super) fn spawn_native_stdout(
    mut receiver: mpsc::Receiver<Value>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut stdout = io::stdout().lock();
        while let Some(message) = receiver.blocking_recv() {
            let Ok(bytes) = serde_json::to_vec(&message) else {
                break;
            };
            let Ok(length) = u32::try_from(bytes.len()) else {
                break;
            };
            if bytes.len() > MAX_NATIVE_REQUEST_BYTES
                || stdout.write_all(&length.to_le_bytes()).is_err()
                || stdout.write_all(&bytes).is_err()
                || stdout.flush().is_err()
            {
                break;
            }
        }
    })
}

pub(super) struct SocketCleanup(pub(super) PathBuf);

impl Drop for SocketCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
