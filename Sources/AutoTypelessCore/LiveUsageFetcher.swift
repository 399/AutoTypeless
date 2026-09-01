import Foundation

public enum LiveUsageFetcher {
    public static func fetch(timeout: TimeInterval = 20) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await fetchFromTypeless(timeout: timeout)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AutoTypelessError.commandFailed("获取用量超时，请确认 Typeless 已登录并稍后重试")
            }
            guard let result = try await group.next() else {
                throw AutoTypelessError.commandFailed("未获取到用量数据")
            }
            group.cancelAll()
            return result
        }
    }

    private static func fetchFromTypeless(timeout: TimeInterval) async throws -> Data {
        let targetsURL = URL(string: "http://127.0.0.1:9223/json/list")!
        let deadline = Date().addingTimeInterval(timeout)

        // Electron 进程出现并不代表页面、IPC 和登录状态已经初始化完成。
        // 启动阶段可能先暴露启动页；这里持续重试，直到真正取得用量或整体超时。
        while Date() < deadline {
            if let (data, _) = try? await URLSession.shared.data(from: targetsURL),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for target in targets where (target["type"] as? String) == "page" {
                    guard
                        let value = target["webSocketDebuggerUrl"] as? String,
                        let webSocketURL = URL(string: value)
                    else { continue }

                    if let usage = try? await fetchFromPage(webSocketURL: webSocketURL) {
                        return usage
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        throw AutoTypelessError.commandFailed("Typeless 已启动，但登录页面尚未准备好或未能返回用量数据")
    }

    private static func fetchFromPage(webSocketURL: URL) async throws -> Data {
        var request = URLRequest(url: webSocketURL)
        request.setValue("http://127.0.0.1:9223", forHTTPHeaderField: "Origin")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let expression = """
        (async()=>{
          if(!window.ipcRenderer) throw new Error("IPC_NOT_READY");
          const token=await window.ipcRenderer.invoke("auth:get-access-token");
          if(!token) throw new Error("TOKEN_NOT_READY");
          const response=await fetch("https://api.typeless.com/user/usage_stats",{
            method:"POST",
            headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},
            body:JSON.stringify({params:{}})
          });
          if(!response.ok) throw new Error("HTTP "+response.status);
          return await response.text();
        })()
        """
        let command: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "awaitPromise": true,
                "returnByValue": true
            ]
        ]
        let commandData = try JSONSerialization.data(withJSONObject: command)
        guard let commandText = String(data: commandData, encoding: .utf8) else {
            throw AutoTypelessError.commandFailed("无法编码 DevTools 请求")
        }
        // Chrome DevTools Protocol 使用文本 JSON 帧；发送二进制帧时 Electron 不会返回命令结果。
        try await socket.send(.string(commandText))

        while true {
            let message = try await socket.receive()
            let responseData: Data
            switch message {
            case .data(let data): responseData = data
            case .string(let string): responseData = Data(string.utf8)
            @unknown default: continue
            }
            guard
                let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                (response["id"] as? Int) == 1
            else { continue }
            guard
                let result = response["result"] as? [String: Any],
                result["exceptionDetails"] == nil,
                let runtimeResult = result["result"] as? [String: Any],
                let value = runtimeResult["value"] as? String
            else {
                throw AutoTypelessError.commandFailed("Typeless 页面尚未准备好")
            }
            return Data(value.utf8)
        }
    }
}
