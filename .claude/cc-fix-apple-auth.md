You are a Senior iOS SwiftUI Engineer. Fix Apple Sign-In race condition in DayPage.

═══ THE BUG ═══
After user completes Apple Sign-In, the AuthView (login page) does NOT dismiss.
User stays stuck on login screen, seeing a loading spinner, instead of transitioning
to the main app. The `fullScreenCover` in RootView fails to dismiss.

═══ ROOT CAUSE ANALYSIS ═══

Three race conditions interact to cause this bug:

**RC1: Double session assignment causes onChange flash**
In `AuthService.swift` line 232, `session` is set directly from `signInWithIdToken` return value.
BUT the `authStateChanges` listener (line 191) ALSO sets `self.session = session` when the
SDK emits the `signedIn` event. During Supabase's internal state transition, the listener
can emit a TEMPORARY nil session between events, causing:
  onChange: nil→userID (dismiss cover) → userID→nil (re-present cover) → nil→userID (dismiss again)
This toggling makes the cover appear to never dismiss.

**RC2: ASAuthorizationController system dialog kills the fullScreenCover**
When `requestAppleAuthorization()` presents the Apple system dialog, iOS may dismiss the
`fullScreenCover` hosting AuthView. After the dialog completes, `showAuthSheet` is still true
so the cover re-presents. Then `session` gets set but the cover is already mid-presentation
and the dismissal animation glitches.

**RC3: isLoading state blocks cover dismissal**
`authService.isLoading = true` on line 213, set to false on line 235.
`viewModel.isLoading = true` in AuthViewModel line 23, set to false on line 27.
The `session` @Published fires at line 232 (or via listener at 191) BEFORE `isLoading = false`.
SwiftUI tries to dismiss the cover while AuthView still shows ProgressView overlay.
The visual result: loading spinner never goes away, user thinks login failed.

═══ FIX INSTRUCTIONS ═══

1. **FIX AuthService.signInWithApple() — remove double session assignment:**
   - Do NOT set `self.session = result` on line 232
   - TRUST ONLY the `authStateChanges` listener for session updates
   - Set `isLoading = false` BEFORE the `signInWithIdToken` call returns the session
   - This eliminates RC1 and RC3

   BEFORE:
   ```swift
   session = try await supabase.auth.signInWithIdToken(...)
   isLoading = false
   ```
   
   AFTER:
   ```swift
   let newSession = try await supabase.auth.signInWithIdToken(...)
   // Do NOT assign to self.session — the listener handles it
   isLoading = false
   // session will be set by authStateChanges listener shortly after
   ```

2. **FIX RootView.onChange — watch a stable boolean, not optional chain:**
   - Replace `.onChange(of: authService.session?.user.id)` with `.onChange(of: authService.session != nil)`
   - This eliminates the nil→UUID→nil→UUID flash from RC1
   - The boolean `session != nil` is stable: false→true on sign-in, true→false on sign-out

   BEFORE:
   ```swift
   .onChange(of: authService.session?.user.id) { newUserID in
       if newUserID != nil { showAuthSheet = false }
       else { showAuthSheet = !authSkipped }
   }
   ```

   AFTER:
   ```swift
   .onChange(of: authService.session != nil) { hasSession in
       if hasSession { showAuthSheet = false }
       else { showAuthSheet = !authSkipped }
   }
   ```

3. **FIX RootView initialization — check session lazily:**
   The @State initializer runs ONCE during init. If the authStateChanges listener hasn't
   delivered the restored session yet, it incorrectly shows auth. Add an `.onAppear` re-check:

   ```swift
   .onAppear {
       // Re-check after AuthService's async setup completes
       if authService.session != nil { showAuthSheet = false }
   }
   ```

4. **FIX ASAuthorizationController — prevent fullScreenCover dismissal:**
   The Apple system dialog may dismiss the cover. To prevent this, set the presentation
   context to the ROOT window instead of the cover's window. In `signInWithApple()`, before
   calling `requestAppleAuthorization()`, internally use a custom presentation anchor
   that's already set up correctly (the current code does this but verify it uses
   `windowScene.windows.first` which should be the root window).

5. **VERIFICATION — read and verify ALL changed files:**
   - AuthService.swift: line 232 should NOT assign to self.session
   - RootView.swift: onChange should use `session != nil`
   - RootView.swift: should have onAppear re-check
   - Build MUST pass: xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5

═══ CRITICAL RULES ═══
- Do NOT change the public API of AuthService
- Do NOT remove Apple Sign-In functionality
- Build after every change
- After fixing, explain WHY each change fixes its respective race condition
