//
//  ViewController.swift
//  DeepAREffectApplying
//
//  Created by Illia Khrypunov on 12.01.2022.
//

import UIKit
import AVKit
import DeepAR

class ViewController: UIViewController {
    // MARK: - Properties
    private var selectedVideoURL = URL(fileURLWithPath: Bundle.main.path(forResource: "testVideo",
                                                                         ofType: "mp4") ?? "")
    private var outputUrl: URL!
    private var effectManager: DeepAREffectsManager?
    private var deepAR: DeepAR!
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupDeepAR()
        setupEffectManager()
    }

    // MARK: - Actions
    @IBAction private func processButtonPressed(_ sender: Any) {
        let maskPath = Effects.rain.rawValue.path ?? ""
        deepAR.switchEffect(withSlot: Mode.effects.rawValue, path: maskPath)
        effectManager?.start()
    }
}

// MARK: - Private
private extension ViewController {
    func setupEffectManager() {
        outputUrl = createOutputUrl(name: "resultVideo.mp4")
        effectManager = DeepAREffectsManager(inputUrl: selectedVideoURL, outputUrl: outputUrl, deepAR: deepAR)
        effectManager?.completion = { [weak self] (error) in
            guard let self = self, error == nil else {
                print(error?.localizedDescription ?? "Error in effect applying")
                return
            }
            self.presentPlayer(url: self.outputUrl)
        }
    }
    
    func setupDeepAR() {
        self.deepAR = DeepAR()
        self.deepAR.setLicenseKey("0053c29f91b569f151fb7f51b854008316532b26bb839f4ab6a80bd165b5652d46e5848d2a36d382")
        self.deepAR.delegate = self
        self.deepAR.initializeOffscreen(withWidth: 1, height: 1)
        self.deepAR.setParameterWithKey("synchronous_vision_initialization", value: "true")
        self.deepAR.changeLiveMode(false)
    }
    
    func presentPlayer(url: URL) {
        let player = AVPlayer(url: url)
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        present(playerViewController, animated: true) {
            playerViewController.player!.play()
        }
    }
    
    func createOutputUrl(name: String) -> URL {
        let path = NSTemporaryDirectory().appending(name)
        let exportURL = URL(fileURLWithPath: path)
        FileManager.default.removeItemIfExisted(exportURL)
        return exportURL
    }
}

// MARK: - DeepARDelegate
extension ViewController: DeepARDelegate {
    func didInitialize() {
        self.deepAR.showStats(true)
        self.deepAR.setFaceDetectionSensitivity(3)
    }
}
