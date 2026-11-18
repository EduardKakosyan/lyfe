import Foundation

/// The network seam: one request in, one response out. Tests replace it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

public enum LyfeAPIError: Error, Equatable, Sendable {
    /// The device token is missing, revoked or unknown.
    case unauthorized
    case wrongPassword
    case tooManyAttempts(retryAfterSeconds: Int)
    /// The backend has no password yet (`lyfe-server set-password`).
    case noPasswordSet
    /// The backend did not answer: Tailscale off, Spark down, no network.
    /// `why` says which, in words that finish "Can't reach the server: …".
    case unreachable(why: String)
    case server(status: Int)
    case unreadableResponse
}

/// The backend's HTTP API, one method per endpoint.
public struct LyfeAPI: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Tells the backend where Apple delivers notifications for this device.
    public func setPushToken(token: String, apnsToken: String) async throws {
        struct Body: Encodable {
            var apnsToken: String
        }
        let body = try JSONEncoder.lyfe.encode(Body(apnsToken: apnsToken))
        _ = try await perform("POST", "v1/push-token", token: token, body: body, timeout: 15)
    }

    /// Whether the backend answers at all, without signing in.
    public func isReachable() async throws {
        _ = try await perform("GET", "healthz", token: nil, body: nil, timeout: 15)
    }

    public func signIn(password: String, deviceName: String) async throws -> String {
        struct Body: Encodable {
            var password: String
            var deviceName: String
        }
        struct Reply: Decodable {
            var token: String
        }
        let body = try JSONEncoder.lyfe.encode(Body(password: password, deviceName: deviceName))
        let reply: Reply = try await call("POST", "v1/auth/sign-in", token: nil, body: body, timeout: 20)
        return reply.token
    }

    public func signOut(token: String) async throws {
        _ = try await perform("POST", "v1/auth/sign-out", token: token, body: nil, timeout: 15)
    }

    public func home(token: String) async throws -> HomeSnapshot {
        try await call("GET", "v1/home", token: token, body: nil, timeout: 15)
    }

    /// Hands the backend a finished breath session. It answers with Home as
    /// it now stands. Sending the same session again changes nothing.
    public func recordBreathSession(token: String, run: BreathRun) async throws -> HomeSnapshot {
        let body = try JSONEncoder.lyfe.encode(BreathSessionUpload(run))
        return try await call("POST", "v1/breath/sessions", token: token, body: body, timeout: 20)
    }

    /// Hands the backend a weight the owner typed. It answers with Home as
    /// it now stands. Sending the same weigh-in again changes nothing.
    /// Kept short: it may be running behind the lock screen, where the
    /// system allows only a few seconds.
    public func recordWeighIn(token: String, weighIn: WeighIn) async throws -> HomeSnapshot {
        let body = try JSONEncoder.lyfe.encode(weighIn)
        return try await call("POST", "v1/weigh-ins", token: token, body: body, timeout: 12)
    }

    /// Hands the backend one tap on a saved meal. It answers with Home as
    /// it now stands. Sending the same tap again changes nothing.
    public func recordFoodEntry(token: String, tap: MealTap) async throws -> HomeSnapshot {
        struct Body: Encodable {
            var id: UUID
            var eatenAt: Date
            var mealId: UUID
            var servings: Double
        }
        let body = try JSONEncoder.lyfe.encode(
            Body(id: tap.id, eatenAt: tap.eatenAt, mealId: tap.mealId, servings: tap.servings))
        return try await call("POST", "v1/food/entries", token: token, body: body, timeout: 15)
    }

    /// Hands the backend a meal logged from a photo and one line. It
    /// answers with Home as it now stands; the estimate follows later.
    /// Sending the same meal again changes nothing.
    public func recordPhotoEntry(token: String, capture: FoodCapture, jpeg: Data?) async throws -> HomeSnapshot {
        guard case .photo(let note, _) = capture.kind else { throw LyfeAPIError.unreadableResponse }
        struct Body: Encodable {
            var id: UUID
            var eatenAt: Date
            var slot: MealSlot
            var note: String
            var photoJpeg: String?
        }
        let body = try JSONEncoder.lyfe.encode(
            Body(
                id: capture.id, eatenAt: capture.eatenAt, slot: capture.slot, note: note,
                photoJpeg: jpeg?.base64EncodedString()))
        // A photo takes longer to send than a tap.
        return try await call("POST", "v1/food/photo-entries", token: token, body: body, timeout: 60)
    }

    /// Hands the backend packaged food logged by its barcode. It answers
    /// with Home as it now stands. Sending the same meal again changes
    /// nothing.
    public func recordBarcodeEntry(token: String, capture: FoodCapture) async throws -> HomeSnapshot {
        guard case .barcode(let code, let grams, _) = capture.kind else { throw LyfeAPIError.unreadableResponse }
        struct Body: Encodable {
            var id: UUID
            var eatenAt: Date
            var slot: MealSlot
            var code: String
            var grams: Double
        }
        let body = try JSONEncoder.lyfe.encode(
            Body(id: capture.id, eatenAt: capture.eatenAt, slot: capture.slot, code: code, grams: grams))
        return try await call("POST", "v1/food/barcode-entries", token: token, body: body, timeout: 15)
    }

    /// A change to a photo meal's estimate.
    public enum EstimateChange: Equatable, Sendable {
        /// The grams of each item the model saw, in order, and the oil.
        case portions(grams: [Double]?, oil: Oil?)
        /// Figures typed instead of the model's.
        case typed(kcal: Int, proteinG: Double)
    }

    /// Corrects a photo meal's estimate. Answers with Home.
    public func correctEstimate(token: String, id: UUID, change: EstimateChange) async throws -> HomeSnapshot {
        struct Body: Encodable {
            var grams: [Double]?
            var oil: Oil?
            var kcal: Int?
            var proteinG: Double?
        }
        let value =
            switch change {
            case .portions(let grams, let oil): Body(grams: grams, oil: oil)
            case .typed(let kcal, let protein): Body(kcal: kcal, proteinG: protein)
            }
        let body = try JSONEncoder.lyfe.encode(value)
        return try await call(
            "PUT", "v1/food/entries/\(id.uuidString.lowercased())/estimate", token: token, body: body, timeout: 15)
    }

    /// The photo of a logged meal, as it was sent.
    public func foodPhoto(token: String, id: UUID) async throws -> Data {
        try await perform("GET", "v1/food/entries/\(id.uuidString.lowercased())/photo", token: token, body: nil, timeout: 20)
    }

    /// The label lyfe has for a barcode, or nil when it has none.
    public func product(token: String, code: String) async throws -> Product? {
        do {
            return try await call("GET", "v1/food/products/\(code)", token: token, body: nil, timeout: 15)
        } catch LyfeAPIError.server(status: 404) {
            return nil
        }
    }

    /// Stores a label typed by hand for a barcode. Meals waiting for it get
    /// their figures. Answers with Home.
    public func setProduct(token: String, product: Product) async throws -> HomeSnapshot {
        struct Body: Encodable {
            var name: String
            var kcalPer100g: Double
            var proteinPer100g: Double
            var servingG: Double?

            enum CodingKeys: String, CodingKey {
                case name
                case kcalPer100g = "kcal_per_100g"
                case proteinPer100g = "protein_per_100g"
                case servingG = "serving_g"
            }
        }
        let body = try JSONEncoder.lyfe.encode(
            Body(
                name: product.name, kcalPer100g: product.kcalPer100g, proteinPer100g: product.proteinPer100g,
                servingG: product.servingG))
        return try await call("PUT", "v1/food/products/\(product.code)", token: token, body: body, timeout: 15)
    }

    /// Takes a logged meal back. Doing it twice changes nothing.
    public func removeFoodEntry(token: String, id: UUID) async throws -> HomeSnapshot {
        try await call("DELETE", "v1/food/entries/\(id.uuidString.lowercased())", token: token, body: nil, timeout: 15)
    }

    /// Stores a saved meal under its id, replacing the recipe when the
    /// meal is already stored.
    public func saveMeal(token: String, draft: MealDraft) async throws -> HomeSnapshot {
        struct Item: Encodable {
            var name: String
            var grams: Double
            var kcalPer100g: Double
            var proteinPer100g: Double

            // Spelled out: the encoder would not put the underscore
            // before the digits.
            enum CodingKeys: String, CodingKey {
                case name, grams
                case kcalPer100g = "kcal_per_100g"
                case proteinPer100g = "protein_per_100g"
            }
        }
        struct Body: Encodable {
            var name: String
            var slot: MealSlot
            var portions: Int
            var ingredients: [Item]
        }
        let items = draft.ingredients.map {
            Item(name: $0.name, grams: $0.grams, kcalPer100g: $0.kcalPer100g, proteinPer100g: $0.proteinPer100g)
        }
        let body = try JSONEncoder.lyfe.encode(
            Body(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), slot: draft.slot,
                portions: draft.portions, ingredients: items))
        return try await call(
            "PUT", "v1/food/meals/\(draft.id.uuidString.lowercased())", token: token, body: body, timeout: 15)
    }

    /// Takes a saved meal out of the list. What was logged from it stays.
    public func removeMeal(token: String, id: UUID) async throws -> HomeSnapshot {
        try await call("DELETE", "v1/food/meals/\(id.uuidString.lowercased())", token: token, body: nil, timeout: 15)
    }

    /// Sets the calorie and protein targets from today on.
    public func setFoodTargets(token: String, targets: FoodTargets) async throws -> HomeSnapshot {
        struct Body: Encodable {
            var kcal: Int
            var proteinG: Int
        }
        let body = try JSONEncoder.lyfe.encode(Body(kcal: targets.kcal, proteinG: targets.proteinG))
        return try await call("PUT", "v1/food/targets", token: token, body: body, timeout: 15)
    }

    /// Asks the backend to check Garmin now. Can take as long as Garmin does.
    public func sync(token: String) async throws -> Sources {
        try await call("POST", "v1/sync", token: token, body: nil, timeout: 45)
    }

    /// Which part of the path failed, with the system's error number so it
    /// can be looked up.
    static func explain(_ error: URLError) -> String {
        let what =
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                "its name was not found; in the Tailscale app, check it is connected and using Tailscale DNS"
            case .timedOut:
                "it did not answer in time"
            case .cannotConnectToHost:
                "it was found but refused the connection; check the port in the address"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                "this device has no network connection"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                .clientCertificateRequired:
                "the secure connection could not be set up"
            case .appTransportSecurityRequiresSecureConnection:
                "the address must be https"
            default:
                "the connection failed"
            }
        return "\(what) (\(error.code.rawValue))"
    }

    private func call<Reply: Decodable>(
        _ method: String, _ path: String, token: String?, body: Data?, timeout: TimeInterval
    ) async throws -> Reply {
        let data = try await perform(method, path, token: token, body: body, timeout: timeout)
        do {
            return try JSONDecoder.lyfe.decode(Reply.self, from: data)
        } catch {
            throw LyfeAPIError.unreadableResponse
        }
    }

    private func perform(
        _ method: String, _ path: String, token: String?, body: Data?, timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as LyfeAPIError {
            // A transport that already knows why it could not get through.
            throw error
        } catch let error as URLError {
            throw LyfeAPIError.unreachable(why: Self.explain(error))
        } catch {
            throw LyfeAPIError.unreachable(why: "the connection failed")
        }

        if (200..<300).contains(response.statusCode) {
            return data
        }
        struct Failure: Decodable {
            var error: String?
            var retryAfterS: Int?
        }
        let failure = try? JSONDecoder.lyfe.decode(Failure.self, from: data)
        switch (response.statusCode, failure?.error) {
        case (401, "wrong_password"): throw LyfeAPIError.wrongPassword
        case (401, _): throw LyfeAPIError.unauthorized
        case (429, _): throw LyfeAPIError.tooManyAttempts(retryAfterSeconds: failure?.retryAfterS ?? 60)
        case (503, "no_password_set"): throw LyfeAPIError.noPasswordSet
        case (502, _), (503, _), (504, _):
            // A proxy in front of a stopped backend answers like this.
            throw LyfeAPIError.unreachable(
                why: "the Spark answered but lyfe is not running on it (\(response.statusCode))")
        default: throw LyfeAPIError.server(status: response.statusCode)
        }
    }
}

/// Turns what the owner typed into the backend's address. A bare host gets
/// `https://`, since the backend is published over HTTPS on the tailnet.
public func serverURL(from text: String) -> URL? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if !trimmed.contains("://") {
        trimmed = "https://" + trimmed
    }
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    guard let components = URLComponents(string: trimmed),
        let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
        let host = components.host, !host.isEmpty,
        components.query == nil, components.fragment == nil
    else { return nil }
    return components.url
}
