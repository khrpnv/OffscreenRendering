//
//  String+Path.swift
//  DeepAREffectApplying
//
//  Created by Illia Khrypunov on 12.01.2022.
//

import Foundation

extension String {
    var path: String? {
        return Bundle.main.path(forResource: self, ofType: nil)
    }
}
