// Which engines-N release the app installs engines from, and the SHA-256 of each file in it.
// Scripts/engines/publish.py attaches this file to every engines release: replace this copy with that
// one to move the app to a new pack (docs/RELEASING.md). Empty until the first engines release.
extension EnginePack {
    static let release: String? = "engines-1"
    static let assets: [String: Asset] = [
        "calibre-arm64": Asset(file: "calibre-9.17.0-universal.tar.xz", sha256: "8bea891914ca07c21f200e36327177bada5e312749ed582618651f382b3f29c4", size: 310647484, minimumSystem: "14.0"),
        "calibre-x86_64": Asset(file: "calibre-9.17.0-universal.tar.xz", sha256: "8bea891914ca07c21f200e36327177bada5e312749ed582618651f382b3f29c4", size: 310647484, minimumSystem: "14.0"),
        "ffmpeg-arm64": Asset(file: "ffmpeg-8.1.3-arm64.tar.xz", sha256: "de10021ed512c2de901d677945145a0d14a71594a380434a780c7eeb87d64cc0", size: 17838404, minimumSystem: "14.0"),
        "ffmpeg-x86_64": Asset(file: "ffmpeg-8.1.3-x86_64.tar.xz", sha256: "576681adc2b68b5dd89b6d2ded61ab8f043e48bbc9a6ba21156e4d3e03b641c0", size: 21444256, minimumSystem: "14.0"),
        "fonttools-arm64": Asset(file: "fonttools-4.68.0-arm64.tar.xz", sha256: "850b528e23b680457b521d0d171747b051e1613432aedb6065bfae78f18fec09", size: 19088204, minimumSystem: "14.0"),
        "fonttools-x86_64": Asset(file: "fonttools-4.68.0-x86_64.tar.xz", sha256: "e15a8acbb1b6247940a22563f4492df556ac4ed85a227e0d743daf97955ad1fb", size: 19292404, minimumSystem: "14.0"),
        "jpeg-xl-arm64": Asset(file: "jpeg-xl-0.12.0-arm64.tar.xz", sha256: "4f8e50c7808708a42800452bef100d408b8327c2ac332464f5a70f96b69dd80f", size: 1278368, minimumSystem: "14.0"),
        "jpeg-xl-x86_64": Asset(file: "jpeg-xl-0.12.0-x86_64.tar.xz", sha256: "0bc019166b3bfcb3e6ddf43e4e69f201b0706de7df53957247057c4a1ddc394b", size: 1566320, minimumSystem: "14.0"),
        "pandoc-arm64": Asset(file: "pandoc-3.13-arm64.tar.xz", sha256: "38a2a0840e081a9faaa2243dda691aa01424cbb542ff8ed5dea463dff99c1ab6", size: 24891236, minimumSystem: "15.0"),
        "pandoc-x86_64": Asset(file: "pandoc-3.13-x86_64.tar.xz", sha256: "64261ec02f01e968df517b8635d14df07d02d5d46dde5f2d996b52c50ae36d1a", size: 16286036, minimumSystem: "15.0"),
        "potrace-arm64": Asset(file: "potrace-1.16-arm64.tar.xz", sha256: "f586fa9012133c1de04c069ac00efd1f1f0cd43c8eb3cb229516e8c5541f0ff4", size: 44668, minimumSystem: "14.0"),
        "potrace-x86_64": Asset(file: "potrace-1.16-x86_64.tar.xz", sha256: "c5e4baa112abc476784f71e6505e3069e95abc3482044484c9b6b155b9070903", size: 54736, minimumSystem: "14.0"),
        "sevenzip-arm64": Asset(file: "sevenzip-26.05-universal.tar.xz", sha256: "6beb63d672b96ef10d4cbc400fd0e07eed29a3f68b71276053b3852f95289399", size: 1886084, minimumSystem: "14.0"),
        "sevenzip-x86_64": Asset(file: "sevenzip-26.05-universal.tar.xz", sha256: "6beb63d672b96ef10d4cbc400fd0e07eed29a3f68b71276053b3852f95289399", size: 1886084, minimumSystem: "14.0"),
        "webp-arm64": Asset(file: "webp-1.6.0-arm64.tar.xz", sha256: "48ac65fff9bfcd97a4770e1d3897c8963052f3201d5d9adfbcb033588a9caf7d", size: 426952, minimumSystem: "14.0"),
        "webp-x86_64": Asset(file: "webp-1.6.0-x86_64.tar.xz", sha256: "72ad42d4bb170e198f575a036aaf65736caa96169dd530d7b5c459d24e4dba35", size: 544104, minimumSystem: "14.0"),
        "woff2-arm64": Asset(file: "woff2-1.0.2-arm64.tar.xz", sha256: "3b53a3d3babdc6d1ba054d78109118762b29b12f2c546f40b7990ebfd62124df", size: 338432, minimumSystem: "14.0"),
        "woff2-x86_64": Asset(file: "woff2-1.0.2-x86_64.tar.xz", sha256: "fcc1156b6dcef549e87975ed7b44a166d197b7e3665ccdbdc5c0802ed3a0e229", size: 380560, minimumSystem: "14.0"),
    ]
}
