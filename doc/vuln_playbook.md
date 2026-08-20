# libjxlz vulnerability response playbook

This is the maintainer procedure for reports received through GitHub private
vulnerability reporting or security@validate.pics. Public reporting guidance
lives in [SECURITY.md](../SECURITY.md).

## 1. Preserve the private report

Keep exploit details, sample files, logs, and proposed fixes inside the private
GitHub advisory or another access-controlled location. Do not copy a sensitive
sample into the public corpus or open a public pull request.

If a report arrives by email and appears credible, create a draft GitHub
Security Advisory and invite the reporter when appropriate.

## 2. Triage the impact

Record:

- the exact libjxlz commit, target, optimize mode, and build path;
- whether the input is attacker-controlled;
- whether the result is a clean rejection, crash, hang, excessive resource
  use, information disclosure, memory corruption, or incorrect acceptance;
- affected public APIs and parent projects;
- the oldest known affected and first known unaffected commits.

Treat out-of-bounds access, use-after-free, integer overflow at allocation or
buffer boundaries, uncontrolled decompression/allocation, and unsafe FFI
lifetime behavior as security-sensitive until disproved.

## 3. Reproduce with an independent control

Create a minimized deterministic reproducer. For business-logic defects, write
and witness a failing persistent test before changing the implementation.

A corrupt-input control must distinguish clean rejection from a signal, timeout,
or unexpected exit. Pair negative controls with valid inputs so a
reject-everything implementation cannot pass. Use an external oracle,
differential test, property test, or separate approver when it materially
improves independence.

Keep the reproducer private until disclosure if it contains exploit-ready
details.

## 4. Develop the fix privately

Use the private advisory fork when GitHub provides one, or another private
working copy. Avoid public branches, CI logs, commit messages, and issue titles
that reveal the vulnerability before disclosure.

Keep ownership cleanup in the same scope as allocation. Use checked arithmetic
at all C and parser boundaries. Preserve specific truncation, malformed-input,
resource-limit, and allocation errors through the strict verdict mapping.

## 5. Verify the repair

Run the focused regression in every affected optimize mode and target practical
for the report. Before release, run:

    ./test
    ./build

Also run the applicable corpus, fuzz reproducer, package C-ABI, cross-build, and
parent-project integration controls. Confirm the fix does not turn valid inputs
into rejections or convert a clean failure into a crash.

## 6. Prepare coordinated disclosure

Agree with the reporter on credit and a practical disclosure date. Determine
whether a released or parent-pinned commit is affected. Prepare:

- the impact and affected-version statement;
- fixed commit or release;
- workaround or mitigation, if any;
- regression-test evidence;
- downstream notification for affected parent projects;
- a GitHub Security Advisory and CVE request when warranted.

No fixed response SLA, disclosure window, bug bounty, or backport policy is
promised during pre-release development.

## 7. Publish and follow through

Publish the fix and advisory together when practical. Notify affected parent
projects privately before public disclosure when they need time to update.
After disclosure, move a non-exploit regression into the public suite and
record the fixed versions or commits.

Review [SECURITY.md](../SECURITY.md) when releases or maintenance commitments
change.
