import Foundation
import Nuke

// Configures Nuke's shared ImagePipeline for player headshots:
//   - 50 MB in-memory decoded-image cache (enough for hundreds of avatars).
//   - 200 MB persistent disk cache under Caches/, survives launches.
//   - URLCache disabled because DataCache already covers the HTTP layer.
//
// Called once from FantasyFootballApp.init() before any view loads.
enum ImagePipelineConfig {
    static func install() {
        var config = ImagePipeline.Configuration()

        // Memory cache for decoded UIImages.
        let memory = ImageCache()
        memory.costLimit = 50 * 1024 * 1024
        memory.countLimit = 500
        config.imageCache = memory

        // Disk cache for raw response data.
        if let disk = try? DataCache(name: "com.fantasyfootball.images") {
            disk.sizeLimit = 200 * 1024 * 1024
            config.dataCache = disk
            // We use DataCache as the only persistence layer; let
            // URLSession skip its own (small, ephemeral) cache.
            config.dataLoader = DataLoader(configuration: {
                let c = DataLoader.defaultConfiguration
                c.urlCache = nil
                c.requestCachePolicy = .reloadIgnoringLocalCacheData
                return c
            }())
        }

        // Headshots are tiny JPEGs — progressive decoding has no upside here.
        config.isProgressiveDecodingEnabled = false

        ImagePipeline.shared = ImagePipeline(configuration: config)
    }
}
