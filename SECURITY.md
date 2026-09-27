# Security policy

## Supported versions

Security fixes go into the `main` branch and ship in the next release of SimplyBar. Older versions do not
receive fixes: please update to the latest release.

| Version | Supported |
|---|---|
| Latest release (1.x) | Yes |
| `main` branch | Yes |
| Older releases | No |

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately, in one of two ways:

1. **GitHub private vulnerability reporting (preferred):** open the
   [Security tab](https://github.com/Iliesseu28/SimplyBar/security) of this repository and click
   **Report a vulnerability**, or go straight to
   <https://github.com/Iliesseu28/SimplyBar/security/advisories/new>.
2. **Email:** write to [contact@simplibot.fr](mailto:contact@simplibot.fr) with "SimplyBar security" in the subject.

Include what you can:

- the version of SimplyBar and of macOS;
- what an attacker could do, and what they need first (local access, another app installed, and so on);
- the steps to reproduce it, or a proof of concept.

## What happens next

- You get an answer within 7 days, usually sooner.
- We confirm the problem, agree with you on a date to disclose it, and work on a fix.
- The fix ships in a new release. With your permission, we credit you in the release notes and in the advisory.

## Scope

Examples of what we want to hear about:

- anything that lets SimplyBar or its widgets reach the network, or leave the App Sandbox;
- data from your Mac exposed to another app or user through the shared App Group container;
- a crash or a hang that another process can trigger on purpose.

Out of scope: issues in macOS itself, and reports that need a Mac already fully under the attacker's control.
