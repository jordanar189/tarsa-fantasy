import UserNotifications

// Notification Service Extension: downloads the image referenced by the
// payload's `image_url` and attaches it so the notification renders with rich
// media. Falls back to the plain text notification when there's no image or the
// download fails/times out.
//
// This file lives OUTSIDE the "Tarsa Fantasy" sources folder so it is not
// compiled into the app. To activate rich images, add a Notification Service
// Extension target in Xcode and point it at this file (see the setup notes the
// assistant provided). Until then, text + scheduling + targeting all work; the
// image simply won't render.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        self.bestAttempt = content

        guard let content else { contentHandler(request.content); return }
        guard let urlString = content.userInfo["image_url"] as? String,
              let url = URL(string: urlString) else {
            contentHandler(content)
            return
        }

        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, _ in
            defer { self?.deliver() }
            guard let tempURL else { return }
            let suggested = response?.suggestedFilename as NSString?
            var ext = suggested?.pathExtension ?? "jpg"
            if ext.isEmpty { ext = "jpg" }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                let attachment = try UNNotificationAttachment(identifier: "image", url: dest)
                content.attachments = [attachment]
            } catch {
                // fall through to text-only
            }
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        deliver()
    }

    private func deliver() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        contentHandler = nil
        handler(content)
    }
}
