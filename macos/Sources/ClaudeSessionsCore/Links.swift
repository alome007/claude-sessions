import Foundation

public func isWebLink(_ target: String) -> Bool {
	target.hasPrefix("https://") || target.hasPrefix("http://")
}
