use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Error, Read};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{UNIX_EPOCH};
use std::{thread};
use warp::{Filter};

const LISTEN_PORT: u16 = 45678;
const MAX_LOG_ENTRIES: usize = 100;
const HASH_BUFFER_SIZE: usize = 65536;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct StartParams {
    pub path: String,
    pub arg: String,
    pub home_dir: Option<String>,
}

#[derive(Debug, Clone)]
struct CachedFileHash {
    path: String,
    size: u64,
    modified_nanos: u128,
    hash: String,
}

static LOGS: Lazy<Arc<Mutex<VecDeque<String>>>> =
    Lazy::new(|| Arc::new(Mutex::new(VecDeque::with_capacity(MAX_LOG_ENTRIES))));
static PROCESS: Lazy<Arc<Mutex<Option<std::process::Child>>>> =
    Lazy::new(|| Arc::new(Mutex::new(None)));
static FILE_HASH_CACHE: Lazy<Arc<Mutex<Option<CachedFileHash>>>> =
    Lazy::new(|| Arc::new(Mutex::new(None)));


fn log_message(message: String) {
    if let Ok(mut log_buffer) = LOGS.lock() {
        if log_buffer.len() >= MAX_LOG_ENTRIES {
            log_buffer.pop_front();
        }
        log_buffer.push_back(message);
    }
}

fn sha256_file_with_lock(file: &File, path: &str) -> Result<String, Error> {
    let metadata = file.metadata()?;
    let modified_nanos = metadata.modified()?
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let size = metadata.len();

    if let Ok(cache_guard) = FILE_HASH_CACHE.lock() {
        if let Some(cache) = cache_guard.as_ref() {
            if cache.path == path && cache.size == size && cache.modified_nanos == modified_nanos {
                return Ok(cache.hash.clone());
            }
        }
    }

    let mut hasher = Sha256::new();
    let mut reader = BufReader::new(file);
    let mut buffer = [0; HASH_BUFFER_SIZE];

    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 { break; }
        hasher.update(&buffer[..n]);
    }

    let hash = format!("{:x}", hasher.finalize());
    if let Ok(mut cache_guard) = FILE_HASH_CACHE.lock() {
        *cache_guard = Some(CachedFileHash {
            path: path.to_string(),
            size,
            modified_nanos,
            hash: hash.clone(),
        });
    }
    Ok(hash)
}

fn start(params: StartParams) -> String {
    let file = match OpenOptions::new().read(true).open(&params.path) {
        Ok(f) => f,
        Err(e) => return format!("Failed to open file: {}", e),
    };

    // 加上共享锁，防止计算 Hash 期间文件被篡改
    if let Err(e) = file.lock_shared() {
        return format!("Failed to lock file: {}", e);
    }

    let sha256 = match sha256_file_with_lock(&file, &params.path) {
        Ok(h) => h,
        Err(e) => { let _ = file.unlock(); return e.to_string(); }
    };

    // 验证 Hash 是否匹配编译时设置的 TOKEN
    if sha256 != env!("TOKEN") {
        let _ = file.unlock();
        return format!("Hash mismatch! Current: {}, Expected: {}", sha256, env!("TOKEN"));
    }

    let _ = file.unlock();
    drop(file); // 显式释放文件句柄

    stop(); // 启动新进程前停止旧进程

    let mut process_guard = PROCESS.lock().unwrap();
    let mut cmd = Command::new(&params.path);
    cmd.arg(&params.arg).stderr(Stdio::piped());
    
    if let Some(hd) = params.home_dir {
        cmd.env("SAFE_PATHS", hd);
    }

    match cmd.spawn() {
        Ok(mut child) => {
            if let Some(stderr) = child.stderr.take() {
                thread::spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines() {
                        if let Ok(l) = line { log_message(l); }
                    }
                });
            }
            *process_guard = Some(child);
            "".to_string() // 成功返回空字符串
        }
        Err(e) => e.to_string(),
    }
}

fn stop() -> String {
    if let Ok(mut p) = PROCESS.lock() {
        if let Some(mut child) = p.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    "".to_string()
}

pub async fn run_service() -> anyhow::Result<()> {
    
    let api_ping = warp::get()
        .and(warp::path("ping"))
        .map(|| env!("TOKEN"));

    let api_start = warp::post()
        .and(warp::path("start"))
        .and(warp::body::json())
        .and_then(|params: StartParams| async move {
            let result = tokio::task::spawn_blocking(move || start(params))
                .await
                .unwrap_or_else(|e| e.to_string());
            
            Ok::<_, warp::Rejection>(warp::reply::with_status(result, warp::http::StatusCode::OK))
        });

    let api_stop = warp::post()
        .and(warp::path("stop"))
        .map(|| {
            warp::reply::with_status(stop(), warp::http::StatusCode::OK)
        });

    let api_logs = warp::get()
        .and(warp::path("logs"))
        .map(|| {
            let log_str = if let Ok(log_buffer) = LOGS.lock() {
                log_buffer.iter().cloned().collect::<Vec<String>>().join("\n")
            } else {
                "".to_string()
            };
            warp::reply::with_header(log_str, "Content-Type", "text/plain")
        });

    let routes = api_ping
        .or(api_start)
        .or(api_stop)
        .or(api_logs);

    warp::serve(routes)
        .run(([127, 0, 0, 1], LISTEN_PORT))
        .await;

    Ok(())
}