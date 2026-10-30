//
//  HumanInterventionVocabulary.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation

/// HumanInterventionVocabulary reads what a control's caption says it does, as a last and optional hint.
/// Structure, keys, window attributes and observed effects decide first; no fact requires a caption.
nonisolated enum HumanInterventionVocabulary {
    enum Meaning: String, Sendable, CaseIterable {
        case create, commit, apply, cancel, close, delete
    }

    /// Whole captions per meaning, lowercased and without accents. A language is added here, never in the engine.
    static let words: [Meaning: [String]] = [
        .create: ["create", "insert", "add", "new",
                  "crea", "inserisci", "aggiungi", "nuovo", "nuova",
                  "creer", "inserer", "ajouter", "nouveau", "nouvelle",
                  "erstellen", "einfugen", "hinzufugen", "neu", "neue", "neuer", "neues",
                  "crear", "insertar", "anadir", "agregar", "nuevo", "nueva"],
        .commit: ["ok", "confirm", "conferma", "confirmer", "bestatigen", "confirmar", "aceptar"],
        .apply: ["apply", "applica", "appliquer", "anwenden", "ubernehmen", "aplicar"],
        .cancel: ["cancel", "annulla", "annuler", "abbrechen", "cancelar"],
        .close: ["close", "chiudi", "fermer", "schliessen", "cerrar", "fechar"],
        .delete: ["delete", "remove", "erase", "trash", "move to trash", "move to bin",
                  "elimina", "rimuovi", "cancella", "sposta nel cestino", "cestina",
                  "supprimer", "effacer", "placer dans la corbeille",
                  "loschen", "entfernen", "in den papierkorb legen",
                  "eliminar", "borrar", "quitar", "mover a la papelera", "excluir", "apagar", "remover"],
    ]

    /// The meaning a whole caption names; with `leadingWord`, also the meaning of its first word ("New Track…").
    static func meaning(of caption: String?, leadingWord: Bool = false) -> Meaning? {
        guard let caption else { return nil }
        let text = caption.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ß", with: "ss")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".…")))
        let first = leadingWord ? text.split(separator: " ").first.map(String.init) : nil
        return Meaning.allCases.first { words[$0]?.contains(text) == true }
            ?? Meaning.allCases.first { meaning in first.map { words[meaning]?.contains($0) == true } == true }
    }
}
