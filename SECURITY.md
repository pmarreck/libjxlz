# Security policy for libjxlz

libjxlz parses untrusted JPEG XL data and is still under active pre-release
development. Please report suspected vulnerabilities privately.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting form:

https://github.com/pmarreck/libjxlz/security/advisories/new

If that form is unavailable, email security@validate.pics.

Do not open a public issue, pull request, or discussion containing exploit
details before the report has been assessed and a disclosure plan agreed.

A useful report includes:

- the affected libjxlz commit or release;
- the operating system, architecture, compiler, and optimize mode;
- a minimized input or deterministic reproduction steps;
- the observed result and expected safety property;
- any known impact, affected parent project, or suggested mitigation;
- the name and affiliation to use for credit, or a request for anonymity.

## Supported versions

libjxlz does not yet have a stable versioned release. Security maintenance
targets the current yolo branch. Parent projects should pin an exact audited
commit and update when a security fix lands.

Older commits, local modifications, and the retained upstream libjxl C++
reference tree are not separate supported libjxlz releases. This policy will be
revised when versioned releases begin.

## Scope

Please report memory-safety failures, out-of-bounds access, integer overflow,
uncontrolled resource consumption, use-after-free, unsafe FFI behavior,
malformed input accepted as valid, or another defect that could affect a host
processing attacker-controlled data.

A failed assertion or ordinary rejection is not automatically a vulnerability.
When uncertain, report privately and let the project classify it.

## Response and disclosure

The project will acknowledge and investigate reports as capacity permits. No
response-time or disclosure-window guarantee is promised during pre-release
development.

Confirmed vulnerabilities will be fixed and tested privately where practical.
The reporter and project will coordinate publication. A GitHub Security
Advisory and CVE will be used when the affected release state and impact warrant
them. Reporter credit will follow the reporter's preference.

Maintainer procedure is documented in
[doc/vuln_playbook.md](doc/vuln_playbook.md).
