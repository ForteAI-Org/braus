// swift-tools-version: 6.4
//
// The Braus side of the Cua Driver comparison: Braus's own AutomationTools over a worker's brokered
// desktop, served over MCP stdio, so one client measures both drivers through the same protocol. A
// benchmark tool, not a product server: the app and the CLI never launch it.

import PackageDescription

let package = Package(
    name: "CUAComparison",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "Braus", path: "../../..")],
    targets: [
        .executableTarget(
            name: "braus-mcp-stdio",
            dependencies: [.product(name: "BrausChat", package: "Braus"),
                           .product(name: "SeatBroker", package: "Braus")],
            path: "Server"
        )
    ]
)
