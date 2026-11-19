import Foundation

enum IOSPhoneRPCDispatchError: Error {
  case notAdmitted
  case invalidated
}

/// The actual HTTP boundary rechecks live authorization immediately before
/// sending, while waiting, and before publishing a reply. Cancelling transport
/// is not an acknowledgement that a remote XCTest action was undone.
@MainActor
enum IOSPhoneRPCDispatch {
  typealias Send = @MainActor (URLRequest) async throws -> (Data, URLResponse)

  static func perform(_ request: URLRequest, permitted: @escaping () -> Bool,
                      send: @escaping Send) async throws -> (Data, URLResponse) {
    guard !Task.isCancelled, permitted() else { throw IOSPhoneRPCDispatchError.notAdmitted }
    let transfer = Task { @MainActor in
      // The task can start after this actor has processed another UI event.
      guard !Task.isCancelled, permitted() else { throw IOSPhoneRPCDispatchError.notAdmitted }
      return try await send(request)
    }
    let monitor = Task { @MainActor in
      while !Task.isCancelled {
        guard permitted() else { transfer.cancel(); return }
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
      }
    }
    defer { monitor.cancel() }
    let result = try await withTaskCancellationHandler(operation: {
      try await transfer.value
    }, onCancel: { transfer.cancel() })
    // Cancellation is sticky even if UI state subsequently becomes admissible
    // again, or an injected/remote transport ignores cancellation and replies.
    guard !Task.isCancelled, !transfer.isCancelled, permitted() else { throw IOSPhoneRPCDispatchError.invalidated }
    return result
  }
}

/// 装载 dataTask 用的盒子，让取消处理能碰到已经发出去的请求。
private final class URLSessionDataTaskBox: @unchecked Sendable {
  var task: URLSessionDataTask?
}

extension URLSession {
  /// iOS 14 兼容的 data(for:)：系统的 async 版 `URLSession.data(for:)` 是 iOS 15 新增，
  /// 这里用 dataTask + withCheckedThrowingContinuation 实现同一语义（iOS 13 就有）。
  /// 取消语义与系统版一致：上层 Task 被取消时立即取消底层请求。
  func dataCompat(for request: URLRequest) async throws -> (Data, URLResponse) {
    let box = URLSessionDataTaskBox()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
        let task = dataTask(with: request) { data, response, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          guard let response else {
            continuation.resume(throwing: URLError(.badServerResponse))
            return
          }
          continuation.resume(returning: (data ?? Data(), response))
        }
        box.task = task
        // 取消可能发生在盒子还没装上任务之前，这里补一次检查。
        if Task.isCancelled { task.cancel() }
        task.resume()
      }
    }, onCancel: {
      box.task?.cancel()
    })
  }
}
