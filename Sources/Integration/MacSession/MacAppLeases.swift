//
//  MacAppLeases.swift
//  Braus
//

import AutomationRuntime

/// MacAppLeases is the native route's name for `AppClaims` (I03): the claims every route of every Braus process takes
/// on an app, by its bundle ID, before anything reaches it. `MacAppLeases()` keeps them within one process, as tests
/// do; the sessions' default, `.shared`, locks them across processes too.
public typealias MacAppLeases = AppClaims
