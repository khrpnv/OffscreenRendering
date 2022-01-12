//
//  AVAsset+Size.swift
//  DeepAREffectApplying
//
//  Created by Illia Khrypunov on 12.01.2022.
//

import AVKit

extension AVAsset {
    var size: CGSize {
        guard let track = self.tracks(withMediaType: AVMediaType.video).first else { return .zero }
        return track.naturalSize.applying(track.preferredTransform)
    }
}
