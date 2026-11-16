/// Selectable latency values for the UI pickers (the only constraint; AppState has no clamps).
/// The converter requires positive multiples of 10. The fixed-F=64 ladder needs block
/// 50/60/70, extra 530/540/550 and crossfade 30 — keep every ladder step expressible here.
public enum LatencyOptions {
    public static let block = [50, 60, 70, 80, 100, 120, 150, 200, 250, 300, 350, 400, 500]
    public static let extra = [200, 300, 500, 530, 540, 550, 750, 1000]
    public static let crossfade = [30, 50, 100, 150, 200]
}