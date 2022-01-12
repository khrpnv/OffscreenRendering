//
//  Effects.swift
//  DeepAREffectApplying
//
//  Created by Illia Khrypunov on 12.01.2022.
//

import Foundation

enum Mode: String {
    case masks
    case effects
    case filters
}

enum Masks: String, CaseIterable {
    case none
    case aviators
    case Helmet_PBR_V1
    case bigmouth
    case dalmatian
    case bcgSeg
    case look2
    case fatify
    case flowers
    case grumpycat
    case koala
    case lion
    case mudMask
    case obama
    case pug
    case slash
    case sleepingmask
    case smallface
    case teddycigar
    case tripleface
    case twistedFace
}

enum Effects: String, CaseIterable {
    case none
    case fire
    case heart
    case blizzard
    case rain
}

enum Filters: String, CaseIterable {
    case none
    case tv80
    case drawingmanga
    case sepia
    case bleachbypass
    case realvhs
    case filmcolorperfection
}
