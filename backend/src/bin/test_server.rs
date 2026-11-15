fn main() {
    if stairclimb::http::run(true).is_err() {
        eprintln!("Stairclimb test fixture startup failed");
        std::process::exit(1);
    }
}
