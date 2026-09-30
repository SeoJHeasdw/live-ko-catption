import SwiftUI

// SDK 27 also exports a State macro, whose plugin is absent from Command Line
// Tools. Name the existing property-wrapper type explicitly for macOS 26 builds.
typealias ViewState<Value> = SwiftUI.State<Value>
