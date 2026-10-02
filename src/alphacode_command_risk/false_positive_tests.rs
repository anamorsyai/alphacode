//! Regression tests for command-risk gate **false positives**.
//!
//! The companion to `bypass_tests.rs`, which protects against the gate being too
//! permissive. This file protects against it being too strict, which is just as
//! damaging in practice: a `Catastrophic` verdict is explicitly "no amount of
//! model justification can unlock it", so a false positive here is not a warning
//! the agent can route around -- it is a command the agent can never run.
//!
//! The specific regression: the defense-in-depth scan for a destructive verb
//! hidden behind an unparseable wrapper also matched *shell names anywhere in
//! the segment*. So a command that merely mentioned a shell was hard-denied.

use super::{RiskContext, RiskLevel, assess};

fn ctx() -> RiskContext {
    RiskContext {
        working_dir: Some(if cfg!(windows) {
            std::path::PathBuf::from("C:\\work\\proj")
        } else {
            std::path::PathBuf::from("/work/proj")
        }),
        home_dir: Some(if cfg!(windows) {
            std::path::PathBuf::from("C:\\Users\\tester")
        } else {
            std::path::PathBuf::from("/home/tester")
        }),
    }
}

fn level_of(command: &str) -> RiskLevel {
    assess(command, &ctx()).level
}

/// A shell name inside a quoted argument is data, not code.
///
/// These are the commands that were denied. Six of seven commands in the
/// original report were ordinary work refused purely for *mentioning* a shell:
/// a grep pattern, a commit message, an echo body.
#[test]
fn mentioning_a_shell_in_quoted_text_is_allowed() {
    for command in [
        r#"grep -rn "sh" src/"#,
        r#"git commit -m "fix the sh wrapper""#,
        r#"echo "run bash later""#,
        r#"grep -r "powershell" docs/"#,
        r#"echo "cmd.exe is documented here""#,
        r#"echo "eval is a builtin""#,
    ] {
        assert_ne!(
            level_of(command),
            RiskLevel::Catastrophic,
            "quoted text is data and must not deny the command: {command}"
        );
    }
}

/// A read-only program cannot execute anything, so a shell name in its argument
/// list is inert by construction.
#[test]
fn a_read_only_program_cannot_execute_a_shell() {
    for command in ["ls sh", "cat bash", "find . -name sh", "grep -rn eval ."] {
        assert_ne!(
            level_of(command),
            RiskLevel::Catastrophic,
            "a read-only program cannot run its arguments: {command}"
        );
    }
}

/// The exemptions above must not open a hole. Every one of these actually does
/// execute something, so every one must still be denied.
#[test]
fn the_exemptions_do_not_admit_real_execution() {
    for command in [
        // `find` is read-only except in these forms -- the whole reason the
        // conditional-flag carve-out exists. This one reaches `/`.
        "find . -exec sh -c 'rm -rf /' \\;",
        // A shell in an *unquoted* operand of a program that can run it.
        "docker run img sh -c 'rm -rf /'",
        "npm run sh",
        // The shell is not the program's program, so the inert/exempt branches
        // must not apply.
        "bash -c \"rm -rf ~\"",
        "powershell -Command \"Remove-Item -Recurse -Force $env:USERPROFILE\"",
    ] {
        assert_eq!(
            level_of(command),
            RiskLevel::Catastrophic,
            "this really does execute something and must stay denied: {command}"
        );
    }
}

/// `find` in a destructive form is still graded as a write, so its operands are
/// path-checked -- the read-only exemption must not swallow the whole segment.
///
/// `find . -delete` is deliberately not `Catastrophic`: it only removes files
/// inside the working directory, which is inside the blast radius this gate
/// accepts. What matters here is that the carve-out keeps the segment on the
/// write path at all.
#[test]
fn find_in_a_destructive_form_still_grades_its_operands() {
    // Below the working directory: allowed.
    assert_ne!(
        level_of("find . -delete"),
        RiskLevel::Catastrophic,
        "deleting inside the working directory is not catastrophic"
    );
    // Outside it, into the home directory: catastrophic.
    assert_eq!(
        level_of("find ~ -delete"),
        RiskLevel::Catastrophic,
        "the same command reaching the home directory must be catastrophic"
    );
}

/// `was_quoted` exists only to answer "is this word executed?", so it must not
/// disturb path comparison: a quoted target has to grade identically to an
/// unquoted one, or quoting becomes a trivial bypass of the protected-path
/// checks.
#[test]
fn quoting_a_path_does_not_change_how_it_is_graded() {
    for (quoted, bare) in [
        (r#"rm -rf "$HOME""#, "rm -rf $HOME"),
        (r#"rm -rf '~'"#, "rm -rf ~"),
    ] {
        assert_eq!(
            level_of(quoted),
            level_of(bare),
            "quoting must not change the risk of a path target: {quoted}"
        );
        assert_eq!(
            level_of(quoted),
            RiskLevel::Catastrophic,
            "a protected-path target stays catastrophic when quoted: {quoted}"
        );
    }
}
