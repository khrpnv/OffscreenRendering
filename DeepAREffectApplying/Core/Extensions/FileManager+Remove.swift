//
//  FileManager+Remove.swift
//  DeepAREffectApplying
//
//  Created by Illia Khrypunov on 12.01.2022.
//

import Foundation

extension FileManager {
    func removeItemIfExisted(_ url:URL) -> Void {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(atPath: url.path)
            }
            catch {
                print("Failed to delete file")
            }
        }
    }
}
