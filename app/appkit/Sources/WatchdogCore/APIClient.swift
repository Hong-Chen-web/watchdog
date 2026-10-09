import Foundation

// MARK: - API 客户端(8790 后端;统一 10s 超时 + snake_case 全局解码)

public enum API {
    public static var base = "http://127.0.0.1:8790"
    /// 本地后端 10s 超时:防止默认 60s 挂起把卡片轮询/启动开窗卡死
    public static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()
    /// 后端统一 snake_case;全局转换杜绝 camelCase 模型静默解码失败(try? 吞掉的根因)
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, _) = try await session.data(from: URL(string: base + path)!)
        return try decoder.decode(T.self, from: data)
    }

    public static func postJSON<T: Decodable>(_ path: String, body: [String: Any]? = nil, as type: T.Type) async throws -> T {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await session.data(for: req)
        return try decoder.decode(T.self, from: data)
    }

    public static func post(_ path: String, body: [String: Any]? = nil) async throws -> Bool {
        try await request("POST", path, body)
    }

    public static func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Bool {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300
    }
}
