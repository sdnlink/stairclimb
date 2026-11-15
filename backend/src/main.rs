fn main() {
    if stairclimb::http::run(false).is_err() {
        eprintln!("Stairclimb startup failed; check local configuration and database availability");
        std::process::exit(1);
    }
}
