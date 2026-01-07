import ExpoModulesCore
import GameKit
import Foundation
import UIKit

// Delegate class to handle GameCenter view controller events
class GameCenterDelegate: NSObject, GKGameCenterControllerDelegate {
  func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
    gameCenterViewController.dismiss(animated: true, completion: nil)
  }
}

public class ExpoGameCenterModule: Module {
  private let gameCenterDelegate = GameCenterDelegate()
  private var authenticationPromise: Promise?
  private var hasSetupAuthHandler = false

  // Cache authentication state to handle race condition
  private var cachedAuthenticationState: Bool?
  private var authenticationHandlerReady = false
  private var storedAuthenticationViewController: UIViewController?
  
  // Required for module registration
  public required init(appContext: AppContext) {
    print("[ExpoGameCenter] *** Module class being initialized ***")
    super.init(appContext: appContext)
    print("[ExpoGameCenter] *** Module initialized successfully ***")
    
    // Set up authentication handler once during module initialization
    setupAuthenticationHandler()
  }
  
  public func definition() -> ModuleDefinition {
    Name("ExpoGameCenter")
    
    OnCreate {
      print("[ExpoGameCenter] *** Module definition created ***")
      print("[ExpoGameCenter] *** GameKit available: true")
    }

    AsyncFunction("isGameCenterAvailable") { (promise: Promise) in
      print("[ExpoGameCenter] isGameCenterAvailable called")
      // GameKit is always available on iOS, but GameCenter might be disabled
      let isAvailable = true
      print("[ExpoGameCenter] GameCenter availability: \(isAvailable)")
      promise.resolve(isAvailable)
    }

    AsyncFunction("authenticateLocalPlayer") { (promise: Promise) in
      print("[ExpoGameCenter] authenticateLocalPlayer called")

      // CRITICAL: Always check REAL authentication state first
      // The cached state might be stale - player could have logged in since handler fired
      let currentAuthState = GKLocalPlayer.local.isAuthenticated
      print("[ExpoGameCenter] Current authentication state: \(currentAuthState)")

      if currentAuthState {
        print("[ExpoGameCenter] Player is authenticated")
        // Update cache to reflect current state
        self.cachedAuthenticationState = true
        self.authenticationHandlerReady = true
        promise.resolve(true)
        return
      }

      // Not currently authenticated - check if handler already fired
      if self.authenticationHandlerReady {
        print("[ExpoGameCenter] Handler already fired, player not authenticated")

        // Check if we have a stored authentication viewController to present
        if let authViewController = self.storedAuthenticationViewController {
          print("[ExpoGameCenter] Found stored auth viewController, presenting it now")
          self.storedAuthenticationViewController = nil  // Clear it
          self.authenticationPromise = promise  // Store promise to resolve after auth

          DispatchQueue.main.async {
            guard let rootViewController = self.getRootViewController() else {
              print("[ExpoGameCenter] No root view controller available")
              promise.resolve(false)
              return
            }

            rootViewController.present(authViewController, animated: true) {
              print("[ExpoGameCenter] Authentication view controller presented")
              // The handler will be called again when user completes authentication
            }
          }

          // Set timeout for user interaction
          DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
            if let pendingPromise = self.authenticationPromise {
              self.authenticationPromise = nil
              print("[ExpoGameCenter] Authentication UI timed out after 30 seconds")
              let finalState = GKLocalPlayer.local.isAuthenticated
              pendingPromise.resolve(finalState)
            }
          }
          return
        }

        // No viewController to present, player just isn't authenticated
        promise.resolve(false)
        return
      }

      // Handler hasn't fired yet - wait for it
      self.authenticationPromise = promise
      print("[ExpoGameCenter] Waiting for authentication handler to fire...")

      // Set a timeout for authentication
      DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
        if let pendingPromise = self.authenticationPromise {
          self.authenticationPromise = nil
          print("[ExpoGameCenter] Authentication timed out after 10 seconds")
          // Check one more time before timing out
          let finalState = GKLocalPlayer.local.isAuthenticated
          print("[ExpoGameCenter] Final auth state before timeout: \(finalState)")
          pendingPromise.resolve(finalState)
        }
      }
    }
    
    AsyncFunction("getConstants") { (promise: Promise) in
      promise.resolve([
        "isGameCenterAvailable": true
      ])
    }
    
    AsyncFunction("getLocalPlayer") { (promise: Promise) in
      guard GKLocalPlayer.local.isAuthenticated else {
        promise.resolve(nil)
        return
      }
      
      let playerInfo = [
        "playerID": GKLocalPlayer.local.gamePlayerID,
        "displayName": GKLocalPlayer.local.displayName,
        "alias": GKLocalPlayer.local.alias
      ]
      promise.resolve(playerInfo)
    }

    AsyncFunction("getPlayerImage") { (promise: Promise) in
      print("[ExpoGameCenter] getPlayerImage called")
      
      guard GKLocalPlayer.local.isAuthenticated else {
        print("[ExpoGameCenter] Player not authenticated for image")
        promise.resolve(nil)
        return
      }
      
      print("[ExpoGameCenter] Loading player photo")
      GKLocalPlayer.local.loadPhoto(for: .small) { image, error in
        DispatchQueue.main.async {
          if let error = error {
            print("[ExpoGameCenter] Image load error: \(error.localizedDescription)")
            promise.resolve(nil)
            return
          }
          
          guard let image = image else {
            print("[ExpoGameCenter] No image returned")
            promise.resolve(nil)
            return
          }
          
          guard let imageData = image.pngData() else {
            print("[ExpoGameCenter] Failed to convert image to PNG data")
            promise.resolve(nil)
            return
          }
          
          let base64String = imageData.base64EncodedString()
          print("[ExpoGameCenter] Image converted to base64")
          promise.resolve("data:image/png;base64,\(base64String)")
        }
      }
    }

    AsyncFunction("submitScore") { (score: Int, leaderboardID: String, promise: Promise) in
      print("[ExpoGameCenter] submitScore called with score: \(score), leaderboard: \(leaderboardID)")
      
      guard GKLocalPlayer.local.isAuthenticated else {
        promise.reject("NOT_AUTHENTICATED", "Player not authenticated")
        return
      }
      
      let scoreReporter = GKScore(leaderboardIdentifier: leaderboardID)
      scoreReporter.value = Int64(score)
      
      GKScore.report([scoreReporter]) { error in
        if let error = error {
          promise.reject("SCORE_SUBMIT_ERROR", error.localizedDescription)
        } else {
          promise.resolve(true)
        }
      }
    }

    AsyncFunction("reportAchievement") { (achievementID: String, percentComplete: Double, promise: Promise) in
      print("[ExpoGameCenter] reportAchievement called: \(achievementID) at \(percentComplete)%")
      
      guard GKLocalPlayer.local.isAuthenticated else {
        promise.reject("NOT_AUTHENTICATED", "Player not authenticated")
        return
      }
      
      let achievement = GKAchievement(identifier: achievementID)
      achievement.percentComplete = percentComplete
      achievement.showsCompletionBanner = true
      
      GKAchievement.report([achievement]) { error in
        if let error = error {
          promise.reject("ACHIEVEMENT_REPORT_ERROR", error.localizedDescription)
        } else {
          promise.resolve(true)
        }
      }
    }

    AsyncFunction("presentLeaderboard") { (leaderboardID: String, promise: Promise) in
      print("[ExpoGameCenter] presentLeaderboard called with ID: \(leaderboardID)")
      
      DispatchQueue.main.async {
        guard let rootViewController = self.getRootViewController() else {
          promise.reject("PRESENTATION_ERROR", "Could not find root view controller")
          return
        }
        
        if #available(iOS 14.0, *) {
          let leaderboardViewController = GKGameCenterViewController(leaderboardID: leaderboardID, playerScope: .global, timeScope: .allTime)
          leaderboardViewController.gameCenterDelegate = self.gameCenterDelegate
          
          rootViewController.present(leaderboardViewController, animated: true) {
            promise.resolve(nil)
          }
        } else {
          // Fallback for iOS 13
          let leaderboardViewController = GKGameCenterViewController()
          leaderboardViewController.gameCenterDelegate = self.gameCenterDelegate
          leaderboardViewController.viewState = .leaderboards
          leaderboardViewController.leaderboardIdentifier = leaderboardID
          
          rootViewController.present(leaderboardViewController, animated: true) {
            promise.resolve(nil)
          }
        }
      }
    }

    AsyncFunction("presentAchievements") { (promise: Promise) in
      print("[ExpoGameCenter] presentAchievements called")
      
      DispatchQueue.main.async {
        guard let rootViewController = self.getRootViewController() else {
          promise.reject("PRESENTATION_ERROR", "Could not find root view controller")
          return
        }
        
        if #available(iOS 14.0, *) {
          let achievementViewController = GKGameCenterViewController(state: .achievements)
          achievementViewController.gameCenterDelegate = self.gameCenterDelegate
          
          rootViewController.present(achievementViewController, animated: true) {
            promise.resolve(nil)
          }
        } else {
          // Fallback for iOS 13
          let achievementViewController = GKGameCenterViewController()
          achievementViewController.gameCenterDelegate = self.gameCenterDelegate
          achievementViewController.viewState = .achievements
          
          rootViewController.present(achievementViewController, animated: true) {
            promise.resolve(nil)
          }
        }
      }
    }

    AsyncFunction("presentGameCenterViewController") { (promise: Promise) in
      print("[ExpoGameCenter] presentGameCenterViewController called")
      
      DispatchQueue.main.async {
        guard let rootViewController = self.getRootViewController() else {
          promise.reject("PRESENTATION_ERROR", "Could not find root view controller")
          return
        }
        
        if #available(iOS 14.0, *) {
          let gameCenterViewController = GKGameCenterViewController(state: .default)
          gameCenterViewController.gameCenterDelegate = self.gameCenterDelegate
          
          rootViewController.present(gameCenterViewController, animated: true) {
            promise.resolve(nil)
          }
        } else {
          // Fallback for iOS 13
          let gameCenterViewController = GKGameCenterViewController()
          gameCenterViewController.gameCenterDelegate = self.gameCenterDelegate
          gameCenterViewController.viewState = .default
          
          rootViewController.present(gameCenterViewController, animated: true) {
            promise.resolve(nil)
          }
        }
      }
    }
  }
  
  // MARK: - Private Methods
  
  private func setupAuthenticationHandler() {
    guard !hasSetupAuthHandler else { return }
    hasSetupAuthHandler = true
    
    print("[ExpoGameCenter] Setting up authentication handler (once)")
    
    GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
      guard let self = self else { return }

      if let error = error {
        print("[ExpoGameCenter] Authentication error: \(error.localizedDescription)")

        // FIX: Cache the error state even if no promise is waiting
        self.cachedAuthenticationState = false
        self.authenticationHandlerReady = true

        if let promise = self.authenticationPromise {
          self.authenticationPromise = nil
          // CRITICAL: Resolve with false instead of rejecting
          // This lets the app handle "not authenticated" gracefully
          print("[ExpoGameCenter] Resolving promise with false due to auth error")
          promise.resolve(false)
        }
        return
      }

      if let viewController = viewController {
        print("[ExpoGameCenter] Authentication handler provided viewController")
        self.authenticationHandlerReady = true

        // If we have a promise waiting, present the viewController immediately
        if let promise = self.authenticationPromise {
          print("[ExpoGameCenter] Promise waiting, presenting auth UI now")
          DispatchQueue.main.async {
            guard let rootViewController = self.getRootViewController() else {
              self.authenticationPromise = nil
              print("[ExpoGameCenter] Could not find root view controller")
              promise.resolve(false)
              return
            }

            rootViewController.present(viewController, animated: true) {
              print("[ExpoGameCenter] Authentication view controller presented")
            }
          }
        } else {
          // No promise waiting yet - store the viewController for later
          print("[ExpoGameCenter] No promise yet, storing viewController for later presentation")
          self.storedAuthenticationViewController = viewController
        }
        return
      }

      // Authentication completed (success or user cancelled)
      let isAuthenticated = GKLocalPlayer.local.isAuthenticated
      print("[ExpoGameCenter] Authentication completed, result: \(isAuthenticated)")

      // FIX: Cache the authentication state even if no promise is waiting
      self.cachedAuthenticationState = isAuthenticated
      self.authenticationHandlerReady = true

      if let promise = self.authenticationPromise {
        self.authenticationPromise = nil
        promise.resolve(isAuthenticated)
      }
    }
  }
  
  private func getRootViewController() -> UIViewController? {
    // iOS 15+ preferred method
    if #available(iOS 15.0, *) {
      if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
         let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
        return window.rootViewController
      }
    }
    
    // Fallback for older iOS versions
    if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
      return window.rootViewController
    }
    
    // Last resort fallback
    return UIApplication.shared.windows.first?.rootViewController
  }
}