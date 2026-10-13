// swift-tools-version: 6.4
//
// The Mecum side of the Cua Driver comparison: Mecum's own AutomationTools over a worker's brokered
// desktop, served over MCP stdio, so one client measures both drivers through the same protocol. A
// benchmark tool, not a product server: the app and the CLI never launch it.

import PackageDescription

let package = Package(
    name: "CUAComparison",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "Mecum", path: "../../..")],
    targets: [
        .executableTarget(
            name: "mecum-mcp-stdio",
            dependencies: [.product(name: "MecumChat", package: "Mecum"),
                           .product(name: "SeatBroker", package: "Mecum")],
            path: "Server"
        )
    ]
)
