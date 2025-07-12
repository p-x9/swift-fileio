//
//  system.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/07/12
//  
//

import Foundation

#if canImport(Darwin)
import Darwin
package let _open = Darwin.open(_:_:)
#elseif canImport(Glibc)
import Glibc
package let _open = Glibc.open(_:_:)
#elseif canImport(Musl)
import Musl
package let _open = Musl.open(_:_:)
#elseif canImport(WASILibc)
import WASILibc
package let _open = WASILibc.open(_:_:)
#elseif canImport(Android)
import Android
package let _open = Android.open(_:_:)
#endif

