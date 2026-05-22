import SwiftUI
import ImageIO
import UIKit

// Plays animated GIFs (and renders plain images) from a remote URL.
// SwiftUI's AsyncImage only shows a GIF's first frame, so chat GIF bubbles
// and the GIF picker grid drive the frames via ImageIO's
// CGAnimateImageDataWithBlock. URLSession.shared's default cache covers the
// HTTP layer, so re-displaying the same GIF is cheap.
struct AnimatedImageView: UIViewRepresentable {
    let url: URL
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        // Let the view size to the SwiftUI frame rather than its content.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode
        context.coordinator.load(url: url, into: uiView)
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Owns the in-flight download and a generation token. Reusing the view
    // for a new URL bumps the generation so the previous GIF's animation
    // block (which runs indefinitely) sees the mismatch and stops itself —
    // otherwise two animations would fight over the same image view.
    final class Coordinator {
        private var loadedURL: URL?
        private var task: URLSessionDataTask?
        private var generation = 0

        func load(url: URL, into imageView: UIImageView) {
            guard loadedURL != url else { return }
            loadedURL = url
            generation &+= 1
            let gen = generation
            task?.cancel()
            imageView.image = nil
            let task = URLSession.shared.dataTask(with: url) { [weak self, weak imageView] data, _, _ in
                guard let self, let data, let imageView else { return }
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.animate(data: data, into: imageView, generation: gen)
                }
            }
            self.task = task
            task.resume()
        }

        func cancel() {
            task?.cancel()
            // Invalidate any running animation block.
            generation &+= 1
        }

        private func animate(data: Data, into imageView: UIImageView, generation gen: Int) {
            let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self, weak imageView] _, cgImage, stop in
                guard let self, let imageView, gen == self.generation else {
                    stop.pointee = true
                    return
                }
                imageView.image = UIImage(cgImage: cgImage)
            }
            // Single-frame / non-animated payloads: render the still directly.
            if status != noErr {
                imageView.image = UIImage(data: data)
            }
        }
    }
}
