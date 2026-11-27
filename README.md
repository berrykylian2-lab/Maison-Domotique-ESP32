# Maison-Domotique-ESP32

Automatisation Blender, Codex et MCP multiplateforme.

## Windows — prototype v0.1

**Non testé sur une machine Windows réelle à ce stade.** Ne pas exécuter sur un ordinateur administré sans autorisation.

1. Télécharger le ZIP de la branche `setup/windows-v1` et extraire tout son contenu.
2. Lire `scripts/install-windows.ps1`. Fermer normalement Blender et Codex.
3. Double-cliquer sur `Lancer-Windows.bat` et confirmer avec O.
4. Si nécessaire, activer MCP for Blender dans les préférences de Blender, puis connecter depuis le panneau N. Se connecter à Codex avec son propre compte.
5. Tester uniquement `get_addon_status` ou un inventaire de scène en lecture seule. Ne pas ouvrir un fichier de travail important pour le premier essai.

Le lanceur recherche Blender, Git et uv ; il installe les exécutables manquants via WinGet. Il prépare Python 3.12 géré par uv, détecte l'application OpenAI ou Codex CLI et installe le CLI via npm en secours. MCP for Blender est épinglé à la version 2.2.1 pour les nouvelles configurations. L'extension existante et tout bloc MCP Blender existant sont conservés ; la compatibilité des versions et des chemins existants doit être vérifiée. Le TOML est validé avant modification et une sauvegarde locale est créée en cas d'ajout à un fichier existant.

Le script ne modifie aucun fichier .blend, ne force pas l'élévation administrateur et ne contourne pas les politiques d'exécution. En cas de blocage WinGet, réseau, PowerShell ou d'installation non standard, consulter le responsable de la machine. Aucun secret ne doit être publié dans ce dépôt public.

Journal local : `%LOCALAPPDATA%\BlenderCodexSetup\setup.log`.

### Critères avant intégration à main

- Tester sur Windows autorisé avec composants manquants.
- Relancer sur le même PC : vérifier l'absence de réinstallation inutile.
- Contrôler la conservation des configurations et le lancement.
- Confirmer la communication MCP en lecture seule.
- Examiner le journal en masquant les informations personnelles avant partage.

macOS et Ubuntu seront traités après validation Windows.

### Documentation

- https://www.mcp-for-blender.com/docs/installation
- https://pypi.org/project/mcp-for-blender/2.2.1/
- https://developers.openai.com/codex/
