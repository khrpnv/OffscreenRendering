//
//  ViewController.swift
//  DeepAREffectApplying
//
//  Created by Illia Khrypunov on 12.01.2022.
//

import UIKit
import AVKit

class ViewController: UIViewController {
    // MARK: - Properties
    private var selectedVideoURL = URL(fileURLWithPath: Bundle.main.path(forResource: "testVideo",
                                                                         ofType: "mp4") ?? "")
    private var effectManager: DeepAREffectsManager?
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupEffectManager()
    }

    // MARK: - Actions
    @IBAction private func processButtonPressed(_ sender: Any) {
        effectManager?.start()
    }
}

// MARK: - Private
private extension ViewController {
    func setupEffectManager() {
        effectManager = DeepAREffectsManager(asset: AVAsset(url: selectedVideoURL),
                                             maskPath: Effects.rain.rawValue.path ?? "",
                                             mode: .effects)
        effectManager?.completion = { [weak self] (exportUrl, error) in
            guard let exportUrl = exportUrl, error == nil else {
                print(error?.localizedDescription ?? "Error in effect applying")
                return
            }
            DispatchQueue.main.async {
                self?.presentPlayer(url: exportUrl)
            }
        }
    }
    
    func presentPlayer(url: URL) {
        let player = AVPlayer(url: url)
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        self.present(playerViewController, animated: true) {
            playerViewController.player!.play()
        }
    }
}
