import Foundation
import Prelude
import Optics

// MARK: - Syntax Router

// TODO: should this be generic over any monoid `M` instead of using `RequestData` directly?
// TODO: generic over an error semigroup too?
public struct Router<A> {
  let parse: (RequestData) -> (rest: RequestData, match: A)?
  let print: (A) -> RequestData?
  let template: (A) -> RequestData?

  public func match(request: URLRequest) -> A? {
    return (self <% end).parse(route(from: request))?.match
  }

  public func match(url: URL) -> A? {
    return match(request: URLRequest(url: url))
  }

  public func match(string: String) -> A? {
    return URL(string: string).flatMap(match(url:))
  }

  public func request(for a: A) -> URLRequest? {
    return self.print(a).flatMap(request(from:))
  }

  public func url(for a: A) -> URL? {
    return self.print(a).flatMap(request(from:)).flatMap { $0.url }
  }

  public func templateRequest(for a: A) -> URLRequest? {
    return self.template(a).flatMap(request(from:))
  }

  public func templateUrl(for a: A) -> URL? {
    return self.templateRequest(for: a).flatMap { $0.url }
  }
}

// Functor

extension Router {
  public func map<B>(_ f: PartialIso<A, B>) -> Router<B> {
    return f <¢> self
  }

  public static func <¢> <B> (lhs: PartialIso<A, B>, rhs: Router) -> Router<B> {
    return Router<B>(
      parse: { route in
        guard let (rest, match) = rhs.parse(route) else { return nil }
        return lhs.apply(match).map { (rest, $0) }
      },
      print: lhs.unapply >-> rhs.print,
      template: lhs.unapply >-> rhs.template
    )
  }
}

// Apply

extension Router {
  /// TODO: use `Tuple`?
  /// Processes with the left and right side routers, and if they succeed returns the pair of their results.
  public static func <%> <B> (lhs: Router, rhs: Router<B>) -> Router<(A, B)> {
    return Router<(A, B)>(
      parse: { str in
        guard let (more, a) = lhs.parse(str) else { return nil }
        guard let (rest, b) = rhs.parse(more) else { return nil }
        return (rest, (a, b))
      },
      print: { ab in
        let lhsPrint = lhs.print(ab.0)
        let rhsPrint = rhs.print(ab.1)
        return (curry(<>) <¢> lhsPrint <*> rhsPrint) ?? lhsPrint ?? rhsPrint
      },
      template: { ab in
        let lhsPrint = lhs.template(ab.0)
        let rhsPrint = rhs.template(ab.1)
        return (curry(<>) <¢> lhsPrint <*> rhsPrint) ?? lhsPrint ?? rhsPrint
    })
  }

  /// Processes with the left and right side routers, discarding the result of the left side.
  public static func %> (x: Router<Prelude.Unit>, y: Router) -> Router {
    return (PartialIso.commute >>> PartialIso.unit.inverted) <¢> x <%> y
  }
}

extension Router where A == Prelude.Unit {
  /// Processes with the left and right routers, discarding the result of the right side.
  public static func <% <B>(x: Router<B>, y: Router) -> Router<B> {
    return PartialIso.unit.inverted <¢> x <%> y
  }
}

// Alternative

extension Router {
  /// Processes with the left side router, and if that fails uses the right side router.
  public static func <|> (lhs: Router, rhs: Router) -> Router {
    return .init(
      parse: { lhs.parse($0) ?? rhs.parse($0) },
      print: { lhs.print($0) ?? rhs.print($0) },
      template: { lhs.template($0) ?? rhs.template($0) }
    )
  }
}

// Plus

extension Router {
  /// A router that always fails and doesn't print anything.
  public static var empty: Router {
    return Router(
      parse: const(nil),
      print: const(nil),
      template: const(nil)
    )
  }
}

private func route(from request: URLRequest) -> RequestData {
  let method = request.httpMethod.flatMap(Method.init(string:)) ?? .get

  guard let components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    else { return .init(method: method, path: [], query: [:], body: request.httpBody) }

  let path = components.path.components(separatedBy: "/")
    |> mapOptional { $0.isEmpty ? nil : $0 }

  var query: [String: String] = [:]
  components.queryItems?.forEach { query[$0.name] = $0.value ?? "" }

  return .init(method: method, path: path, query: query, body: request.httpBody)
}

private func request(from route: RequestData) -> URLRequest? {

  return urlComponents(from: route).url.map {
    URLRequest(url: $0)
      |> \.httpMethod .~ route.method?.rawValue
      |> \.httpBody .~ route.body
  }
}

private func urlComponents(from route: RequestData) -> URLComponents {
  var components = URLComponents()
  components.path = route.path.joined(separator: "/")

  if !route.query.isEmpty {
    components.queryItems = route.query
      .sorted { lhs, rhs in lhs.key < rhs.key }
      .map(URLQueryItem.init(name:value:))
  }

  return components
}