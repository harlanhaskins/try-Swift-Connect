//
//  ViewController.swift
//  try! Swift Connect
//
//  Created by Harlan Haskins on 9/6/17.
//  Copyright © 2017 harlanhaskins. All rights reserved.
//

import BarcodeScanner
import MessageUI
import PassKit
import SVProgressHUD
import UIKit

enum Result<T> {
    case success(T)
    case failure(Error)
}

enum ScanError: Error {
    case notURL(String)
    case invalidPass
}

class ViewController: UIViewController,
    BarcodeScannerErrorDelegate,
    BarcodeScannerCodeDelegate,
    BarcodeScannerDismissalDelegate,
    MFMailComposeViewControllerDelegate,
    UINavigationControllerDelegate {

    func showError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: "\(error)",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    func didDownloadData(_ data: Data) {
        defer {
            SVProgressHUD.dismiss()
        }
        var error: NSError?
        let pass = PKPass(data: data, error: &error)
        if let error = error {
            self.showError(error)
            return
        }

        if let twitter = pass.localizedValue(forFieldKey: "twitter") as? String,
            !twitter.contains("http") {
            openTwitter(twitter)
        } else if let email = pass.localizedValue(forFieldKey: "email") as? String {
            let composer = MFMailComposeViewController()
            composer.setSubject("try! Swift Connection")
            composer.setToRecipients([email])
            composer.setMessageBody(
                "Hi! Nice meeting you at try! Swift NYC 2017!\nJust sending you a quick email from the try! Swift Connect app so we can stay connected.",
                isHTML: false)
            composer.mailComposeDelegate = self
            self.present(composer, animated: true)
        }
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        if let error = error {
            showError(error)
        }
        dismiss(animated: true)
    }

    func openTwitter(_ user: String) {
        if let tweetbotURL = URL(string: "tweetbot://\(user)/user_profile/\(user)") {
            if UIApplication.shared.canOpenURL(tweetbotURL) {
                UIApplication.shared.open(tweetbotURL)
                return
            }
        }

        if let twitterURL = URL(string: "twitter:///user?screen_name=\(user)") {
            if UIApplication.shared.canOpenURL(twitterURL) {
                UIApplication.shared.open(twitterURL)
                return
            }
        }

        if let webURL = URL(string: "http://www.twitter.com/\(user)") {
            if UIApplication.shared.canOpenURL(webURL) {
                UIApplication.shared.open(webURL)
            }
        }
    }

    func handle(result: Result<URL>) {
        switch result {
        case .success(let url):
            SVProgressHUD.show(withStatus: "Loading Attendee Information...")
            let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let `self` = self else { return }

                if let error = error {
                    self.showError(error)
                    return
                }

                guard let data = data else {
                    print("no data and no url?")
                    return
                }

                DispatchQueue.main.async {
                    self.didDownloadData(data)
                }
            }
            task.resume()
        case .failure(let error):
            print(error)
        }
    }

    func barcodeScanner(_ controller: BarcodeScannerController, didReceiveError error: Error) {
        handle(result: .failure(error))
        dismiss(animated: true)
    }

    func barcodeScanner(_ controller: BarcodeScannerController,
                        didCaptureCode code: String, type: String) {
        dismiss(animated: true)

        guard let url = URL(string: code) else {
            showError(ScanError.notURL(code))
            return
        }

        handle(result: .success(url))

    }

    func barcodeScannerDidDismiss(_ controller: BarcodeScannerController) {
        print("Scanner dismissed")
    }


    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    @IBAction func showScanner(_ sender: UIButton) {
        let scanner = BarcodeScannerController()
        scanner.codeDelegate = self
        scanner.errorDelegate = self
        scanner.dismissalDelegate = self

        present(scanner, animated: true)
    }
    
}

