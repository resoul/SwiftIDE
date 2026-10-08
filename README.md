# FontManager

[![Swift Package Manager compatible](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20tvOS-lightgrey.svg)](https://swift.org/package-manager/)
[![Swift](https://img.shields.io/badge/swift-5.9-orange.svg)](https://swift.org)

`FontManager` is a Swift Package that provides a convenient way to manage and use custom fonts (such as Montserrat and Roboto) in iOS, macOS, tvOS, and watchOS applications.

The package allows for selective loading of only the font families you need, helping to reduce app size and optimize performance.

## 🚀 Getting Started

### 1. Adding to your Project

To add `FontManager` to your Xcode project, select **File > Add Packages...** and paste the repository URL:
https://github.com/resoul/FontManager

### 2. Loading Fonts

In your `AppDelegate` (for UIKit) or in the `init()` of your `App` (for SwiftUI), call the `registerFonts()` method, passing the font families you want to use.

For example, to load only the Montserrat family:

```swift
import FontManager

FontManager.registerFonts(fontFamily: Fonts.Montserrat.self)
```
3. Using Fonts
   After registration, you can use the fonts in your code.

```swift
import UIKit
import FontManager

let label = UILabel()
label.font = UIFont.montserrat(.regular, size: 20)
```
