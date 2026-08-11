use std::mem;
use std::ops::ControlFlow;
use std::path::Path;

use oxc::ast::ast::{Program, Statement};
use oxc::ast::ast_kind::AstKind;
use oxc::ast_visit::{Visit, walk};
use oxc::codegen::CodegenReturn;
use oxc::diagnostics::OxcDiagnostic;
use oxc::parser::ParserReturn;
use oxc::span::{GetSpan, SourceType};
use oxc::transformer::{TransformOptions, TransformerReturn};
use oxc::{CompilerInterface, allocator::Allocator, parser::Parser};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// Whether source is a replayable cell or a callable single-file skill module.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    /// A global cell. ESM declarations and dynamic imports are forbidden.
    Cell,
    /// A module with exactly one default export and no imports.
    SkillModule,
}

/// Deterministic JavaScript emitted by Oxc.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompiledSource {
    /// Type-stripped JavaScript.
    pub javascript: String,
    /// SHA-256 of the original UTF-8 source.
    pub source_digest: String,
    /// SHA-256 of the emitted UTF-8 JavaScript.
    pub compiled_digest: String,
}

/// Source admission/compilation failure.
#[derive(Debug, Error)]
pub enum CompileError {
    /// The source uses syntax deliberately outside the runtime contract.
    #[error("source is not admitted: {0}")]
    NotAdmitted(String),
    /// Oxc rejected the source.
    #[error("TypeScript compilation failed: {0}")]
    Diagnostic(String),
}

#[derive(Default)]
struct AdmissionVisitor {
    kind: Option<SourceKind>,
    failures: Vec<&'static str>,
    default_exports: usize,
}

impl<'a> Visit<'a> for AdmissionVisitor {
    fn enter_node(&mut self, kind: AstKind<'a>) {
        match kind {
            AstKind::ImportDeclaration(_) | AstKind::ImportExpression(_) => {
                self.failures.push("module loading is unavailable")
            }
            AstKind::ExportDefaultDeclaration(_) => {
                self.default_exports += 1;
                if self.kind == Some(SourceKind::Cell) {
                    self.failures.push("cell exports are unavailable");
                }
            }
            AstKind::ExportNamedDeclaration(_) | AstKind::ExportAllDeclaration(_) => {
                self.failures.push("named exports are unavailable")
            }
            AstKind::TSEnumDeclaration(_) | AstKind::TSModuleDeclaration(_) => self
                .failures
                .push("runtime TypeScript enums/namespaces are unavailable"),
            AstKind::IdentifierName(value) if value.name.starts_with("__tron") => self
                .failures
                .push("identifiers beginning with __tron are reserved"),
            AstKind::IdentifierReference(value) if value.name.starts_with("__tron") => self
                .failures
                .push("identifiers beginning with __tron are reserved"),
            AstKind::BindingIdentifier(value) if value.name.starts_with("__tron") => self
                .failures
                .push("identifiers beginning with __tron are reserved"),
            _ => {}
        }
    }

    fn visit_program(&mut self, program: &Program<'a>) {
        walk::walk_program(self, program);
    }
}

#[derive(Default)]
struct StripCompiler {
    output: String,
    errors: Vec<OxcDiagnostic>,
    options: TransformOptions,
}

impl CompilerInterface for StripCompiler {
    fn transform_options(&self) -> Option<&TransformOptions> {
        Some(&self.options)
    }

    fn handle_errors(&mut self, errors: Vec<OxcDiagnostic>) {
        self.errors.extend(errors);
    }

    fn after_codegen(&mut self, result: CodegenReturn) {
        self.output = result.code;
    }

    fn after_parse(&mut self, _result: &mut ParserReturn) -> ControlFlow<()> {
        ControlFlow::Continue(())
    }

    fn after_transform(
        &mut self,
        _program: &mut Program<'_>,
        _result: &mut TransformerReturn,
    ) -> ControlFlow<()> {
        ControlFlow::Continue(())
    }
}

/// Validate and strip TypeScript without executing or resolving any module.
pub fn compile_typescript(source: &str, kind: SourceKind) -> Result<CompiledSource, CompileError> {
    let source_type = match kind {
        // Cells are parsed as modules solely to admit top-level await. The AST
        // admission visitor still rejects every import/export form.
        SourceKind::Cell => SourceType::ts().with_module(true),
        SourceKind::SkillModule => SourceType::ts().with_module(true),
    };
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if !parsed.errors.is_empty() {
        return Err(CompileError::Diagnostic(format_diagnostics(&parsed.errors)));
    }

    let mut admission = AdmissionVisitor {
        kind: Some(kind),
        ..AdmissionVisitor::default()
    };
    admission.visit_program(&parsed.program);
    if kind == SourceKind::SkillModule && admission.default_exports != 1 {
        admission
            .failures
            .push("a skill module must have exactly one default export");
    }
    if let Some(failure) = admission.failures.first() {
        return Err(CompileError::NotAdmitted((*failure).to_owned()));
    }

    let mut compiler = StripCompiler::default();
    compiler.options.typescript.allow_namespaces = false;
    compiler.compile(source, source_type, Path::new("runtime.ts"));
    if !compiler.errors.is_empty() {
        return Err(CompileError::Diagnostic(format_diagnostics(
            &compiler.errors,
        )));
    }
    let javascript = mem::take(&mut compiler.output);
    Ok(CompiledSource {
        source_digest: digest(source.as_bytes()),
        compiled_digest: digest(javascript.as_bytes()),
        javascript,
    })
}

fn format_diagnostics(diagnostics: &[OxcDiagnostic]) -> String {
    diagnostics
        .iter()
        .take(4)
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("; ")
}

pub(crate) fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Rewrite the candidate's final expression into the private result slot used
/// by the one-module journal assembly. Non-expression cells produce the
/// explicit undefined sentinel.
pub(crate) fn capture_candidate_result(javascript: &str) -> Result<String, CompileError> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, javascript, SourceType::mjs()).parse();
    if !parsed.errors.is_empty() {
        return Err(CompileError::Diagnostic(format_diagnostics(&parsed.errors)));
    }
    let Some(Statement::ExpressionStatement(statement)) = parsed.program.body.last() else {
        return Ok(format!(
            "{javascript}\n;globalThis.__tronCellResult = {{\"$tron\":\"undefined\"}};"
        ));
    };
    let expression = statement.expression.span();
    let start = usize::try_from(expression.start).unwrap_or(javascript.len());
    let end = usize::try_from(expression.end).unwrap_or(javascript.len());
    if start > end || end > javascript.len() {
        return Err(CompileError::Diagnostic(
            "Oxc emitted an invalid candidate result span".to_owned(),
        ));
    }
    Ok(format!(
        "{}globalThis.__tronCellResult = await ({});{}",
        &javascript[..start],
        &javascript[start..end],
        &javascript[end..]
    ))
}
