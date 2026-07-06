pub fn format_bytes(bytes: u64) -> String {
    if bytes == 0 {
        return "0 B".into();
    }
    const K: f64 = 1024.0;
    let sizes = ["B", "KiB", "MiB", "GiB", "TiB"];
    let bytes_f = bytes as f64;
    let i = (bytes_f.ln() / K.ln()).floor() as usize;
    let i = i.min(sizes.len() - 1);
    format!("{:.1} {}", bytes_f / K.powi(i as i32), sizes[i])
}