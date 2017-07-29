//
//  SpotifyLogin.swift
//  SpotifyLogin
//
//  Created by Roy Marmelstein on 2017-05-09.
//  Copyright © 2017 Spotify. All rights reserved.
//

import Foundation
import SafariServices

/// Spotify login object.
public class SpotifyLogin {

    /// Shared instance.
    public static let shared = SpotifyLogin()

    private var clientID: String?
    private var clientSecret: String?
    private var redirectURL: URL?
    private var requestedScopes: [String]?

    internal var _session: Session?
    public var session: Session? {
        get {
            if _session == nil {
                return KeychainService.loadSession()
            }
            return _session
        }
        set {
            _session = newValue
            KeychainService.save(session: newValue)
        }
    }

    // MARK: Interface

    /// Configure login object.
    ///
    /// - Parameters:
    ///   - clientID: App's client id.
    ///   - clientSecret: App's client secret.
    ///   - redirectURL: App's redirect url.
    ///   - requestedScopes: Requested scopes.
    public func configure(clientID: String, clientSecret: String, redirectURL: URL) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURL = redirectURL
    }


    /// Asynchronous call to retrieve the session's auth token. Automatically refreshes if auth token expired. 
    ///
    /// - Parameter completion: Returns the auth token as a string if available and an optional error.
    public func getAccessToken(completion:@escaping (String?, Error?) -> ()) {
        // If the login object is not fully configured, return an error
        guard clientID != nil, clientSecret != nil, redirectURL != nil else {
            completion(nil, LoginError.ConfigurationMissing)
            return
        }
        // If there is no session, return an error
        guard let session = self.session else {
            completion(nil, LoginError.NoSession)
            return
        }
        // If session is valid return access token, otherwsie refresh
        if session.isValid() {
            completion(session.accessToken, nil)
            return
        } else {
            self.renewSession(callback: { (error, session) in
                if let session = session, error == nil {
                    completion(session.accessToken, nil)
                } else {
                    completion(nil, error)
                }
            })
        }
    }


    /// Trigger log in flow.
    ///
    /// - Parameter viewController: The view controller that orignates the log in flow.
    public func login(from viewController: UIViewController, scopes requestedScopes:[Scope]) {
        self.requestedScopes = requestedScopes.map({$0.rawValue})
        if let appAuthenticationURL = appAuthenticationURL(), UIApplication.shared.canOpenURL(appAuthenticationURL) {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(appAuthenticationURL, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.openURL(appAuthenticationURL)
            }
        } else if let webAuthenticationURL = webAuthenticationURL() {
            viewController.definesPresentationContext = true
            let safariVC: SFSafariViewController = SFSafariViewController(url: webAuthenticationURL)
       //     safariVC.delegate = viewController
            safariVC.modalPresentationStyle = .pageSheet
            viewController.present(safariVC, animated: true, completion: nil)
        } else {
            assertionFailure("Unable to login.")
        }
    }

    public func handleAuthCallback(url: URL, callback: @escaping (Error?, Session?) -> ()) {
        let parsedURL = parse(url: url)
        if parsedURL.error  {
            callback(LoginError.General, nil)
            return
        }

        if let code = parsedURL.code, let redirectURL = self.redirectURL, let authString = self.clientSecret?.data(using: .ascii)?.base64EncodedString(options: .endLineWithLineFeed) {
            let endpoint = URL(string: APITokenEndpointURL)!
            var urlRequest = URLRequest(url: endpoint)
            let authHeaderValue = "Basic \(authString)"
            let requestBodyString = "code=\(code)&grant_type=authorization_code&redirect_uri=\(redirectURL)"
            urlRequest.addValue(authHeaderValue, forHTTPHeaderField: "Authorization")
            urlRequest.addValue("application/x-www-form-urlencoded" , forHTTPHeaderField: "content-type")
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = requestBodyString.data(using: .utf8)
            let task = URLSession.shared.dataTask(with: urlRequest, completionHandler: { [weak self] (data, response, error) in
                if (error != nil) {
                    DispatchQueue.main.async {
                        callback(error, nil)
                    }
                    return
                }
                if let data = data, let authResponse = try? JSONDecoder().decode(TokenEndpointResponse.self, from: data) {
                    SpotifyLoginNetworking.fetchUsername(accessToken: authResponse.access_token, completion: { (username) in
                        if let username = username {
                            let session = Session(userName: username, accessToken: authResponse.access_token, encryptedRefreshToken: authResponse.refresh_token, expirationDate: Date(timeIntervalSinceNow: authResponse.expires_in))
                            self?.session = session
                            DispatchQueue.main.async {
                                callback(nil, session)
                            }
                        }
                    })
                }
            })
            task.resume()
        }
    }

    public func canHandleURL(_ url: URL) -> Bool {
        guard let redirectURLString = redirectURL?.absoluteString else {
            return false
        }
        return url.absoluteString.hasPrefix(redirectURLString)
    }

    // MARK: Private

    private func renewSession(callback: @escaping (Error?, Session?) -> ()) {
        guard let session = self.session, let encryptedRefreshToken = session.encryptedRefreshToken else {
            callback(LoginError.NoSession, nil)
            return
        }
        let endpoint = URL(string: APITokenEndpointURL)!
        let formDataString = "grant_type=refresh_token&refresh_token=\(encryptedRefreshToken)"
        var urlRequest = URLRequest(url: endpoint)
        if let authString = self.clientSecret?.data(using: .ascii)?.base64EncodedString(options: .endLineWithLineFeed) {
            let authHeaderValue = "Basic \(authString)"
            urlRequest.addValue(authHeaderValue, forHTTPHeaderField: "Authorization")
        }
        urlRequest.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = formDataString.data(using: .utf8)
        urlRequest.httpMethod = "POST"
        let task = URLSession.shared.dataTask(with: urlRequest, completionHandler: { [weak self] (data, response, error) in
            if (error != nil) {
                DispatchQueue.main.async {
                    callback(error, nil)
                }
                return
            }
            if let data = data, let authResponse = try? JSONDecoder().decode(TokenEndpointResponse.self, from: data) {
                let session = Session(userName: session.userName, accessToken: session.accessToken, encryptedRefreshToken: authResponse.refresh_token, expirationDate: Date(timeIntervalSinceNow: authResponse.expires_in))
                self?.session = session
                DispatchQueue.main.async {
                    callback(nil, session)
                }
            }
        })
        task.resume()
    }

    private class func spotifyApplicationIsInstalled() -> Bool {
        return UIApplication.shared.canOpenURL(URL(string: "spotify:")!)
    }

    private func webAuthenticationURL() -> URL? {
        return authenticationURL(endpoint: AuthServiceEndpointURL)
    }

    private func appAuthenticationURL() -> URL? {
        return authenticationURL(endpoint: Constants.AppAuthURL)
    }

    private func authenticationURL(endpoint: String) -> URL? {
        return loginURL(scopes: self.requestedScopes, campaignID: Constants.AuthUTMMediumCampaignQueryValue, endpoint: endpoint)
    }


    private func loginURL(scopes: [String]?, responseType: String = "code", campaignID: String = Constants.AuthUTMMediumCampaignQueryValue, endpoint: String = AuthServiceEndpointURL) -> URL? {
        guard let clientID = self.clientID, let redirectURL = self.redirectURL, let scopes = scopes else {
            return nil
        }

        var params = ["client_id": clientID, "redirect_uri": redirectURL.absoluteString, "response_type": responseType, "show_dialog": "true", "nosignup": "true", "nolinks": "true", "utm_source": "spotify-sdk", "utm_medium": "ios-sdk", "utm_campaign": campaignID]

        if (scopes.count > 0) {
            params["scope"] = scopes.joined(separator: " ")
        }

        let pairs = params.map{"\($0)=\($1)"}
        let pairsString = pairs.joined(separator: "&").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ??  String()

        let loginPageURLString = "\(endpoint)authorize?\(pairsString)"
        return URL(string: loginPageURLString)
    }

    private func parse(url: URL) -> (code: String?, error: Bool) {
        var code: String?
        var error = false
        if let fragment = url.query {
            let fragmentItems = fragment.components(separatedBy: "&").reduce([String:String]()) { (dict, fragmentItem) in
                var mutableDict = dict
                let splitValue = fragmentItem.components(separatedBy: "=")
                mutableDict[splitValue[0]] = splitValue[1]
                return mutableDict
            }
            code = fragmentItems["code"]
            error = fragment.contains("error")
        }
        return (code: code, error: error)
    }

}