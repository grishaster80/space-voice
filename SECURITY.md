# Security

Please report vulnerabilities privately through [GitHub security advisories](https://github.com/grishaster80/space-voice/security/advisories/new).
Do not post credentials or private recordings in issues or pull requests.

Space Voice reads existing local sign-ins only for the transcription engine you use.
Cloud engines send audio to their provider. The bb engine delegates to the voice service configured in bb.
Apple recognition runs on device after the required language assets are downloaded.

API keys belong in the macOS login keychain, never in the repository.
Do not commit `.env` files, `auth.json`, keychain exports, signing certificates or recordings.
When all transcription attempts fail, the app retains the last failed recording in its cache;
see the README for the location.
