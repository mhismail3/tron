//! Deterministic robots.txt parser and decision selection.

use serde_json::{Value, json};

const MAX_SITEMAPS: usize = 20;

pub(super) struct ParsedRobots {
    pub(super) matched_user_agent: Option<String>,
    pub(super) rules: Vec<RobotsRule>,
    pub(super) sitemaps: Vec<String>,
    pub(super) sitemaps_truncated: bool,
}

#[derive(Clone)]
pub(super) struct RobotsRule {
    directive: &'static str,
    pattern: String,
    line: usize,
}

pub(super) fn parse_robots(body: &str, user_agent: &str, target_path: String) -> ParsedRobots {
    let mut groups = Vec::<RobotsGroup>::new();
    let mut current_agents = Vec::<String>::new();
    let mut current_rules = Vec::<RobotsRule>::new();
    let mut sitemaps = Vec::new();
    let mut sitemaps_truncated = false;
    for (index, raw_line) in body.lines().enumerate() {
        let line_number = index.saturating_add(1);
        let line = raw_line
            .split_once('#')
            .map_or(raw_line, |(prefix, _)| prefix)
            .trim();
        if line.is_empty() {
            if !current_agents.is_empty() || !current_rules.is_empty() {
                groups.push(RobotsGroup {
                    agents: std::mem::take(&mut current_agents),
                    rules: std::mem::take(&mut current_rules),
                });
            }
            continue;
        }
        let Some((field, value)) = line.split_once(':') else {
            continue;
        };
        let field = field.trim().to_ascii_lowercase();
        let value = value.trim();
        match field.as_str() {
            "user-agent" => {
                if !current_rules.is_empty() {
                    groups.push(RobotsGroup {
                        agents: std::mem::take(&mut current_agents),
                        rules: std::mem::take(&mut current_rules),
                    });
                }
                if !value.is_empty() {
                    current_agents.push(value.to_ascii_lowercase());
                }
            }
            "allow" if !current_agents.is_empty() => current_rules.push(RobotsRule {
                directive: "allow",
                pattern: value.to_owned(),
                line: line_number,
            }),
            "disallow" if !current_agents.is_empty() => current_rules.push(RobotsRule {
                directive: "disallow",
                pattern: value.to_owned(),
                line: line_number,
            }),
            "sitemap" => {
                if sitemaps.len() < MAX_SITEMAPS {
                    sitemaps.push(value.to_owned());
                } else {
                    sitemaps_truncated = true;
                }
            }
            _ => {}
        }
    }
    if !current_agents.is_empty() || !current_rules.is_empty() {
        groups.push(RobotsGroup {
            agents: current_agents,
            rules: current_rules,
        });
    }

    let user_agent = user_agent.to_ascii_lowercase();
    let mut best_specificity = None::<usize>;
    let mut matched_agents = Vec::<String>::new();
    let mut matched_rules = Vec::<RobotsRule>::new();
    for group in groups {
        let specificity = group
            .agents
            .iter()
            .filter_map(|agent| user_agent_specificity(&user_agent, agent))
            .max();
        let Some(specificity) = specificity else {
            continue;
        };
        match best_specificity {
            None => {
                best_specificity = Some(specificity);
                matched_agents = group.agents;
                matched_rules = group.rules;
            }
            Some(best) if specificity > best => {
                best_specificity = Some(specificity);
                matched_agents = group.agents;
                matched_rules = group.rules;
            }
            Some(best) if specificity == best => {
                matched_agents.extend(group.agents);
                matched_rules.extend(group.rules);
            }
            _ => {}
        }
    }
    let matched_user_agent = matched_agents.into_iter().next();
    let rules = matched_rules
        .into_iter()
        .filter(|rule| {
            rule.directive == "allow" && !rule.pattern.is_empty()
                || rule.directive == "disallow" && !rule.pattern.is_empty()
        })
        .filter(|rule| rule_matches(&rule.pattern, &target_path))
        .collect();
    ParsedRobots {
        matched_user_agent,
        rules,
        sitemaps,
        sitemaps_truncated,
    }
}

struct RobotsGroup {
    agents: Vec<String>,
    rules: Vec<RobotsRule>,
}

pub(super) struct RobotsDecision {
    pub(super) decision: &'static str,
    pub(super) reason: &'static str,
    pub(super) rule: Value,
}

pub(super) fn decision_for_status(
    status: u16,
    missing: bool,
    body_truncated: bool,
    parsed: &ParsedRobots,
) -> RobotsDecision {
    if missing {
        return empty_decision("allow", "robots_missing");
    }
    if matches!(status, 401 | 403) {
        return empty_decision("deny", "robots_status_denies_all");
    }
    if status >= 500 {
        return empty_decision("deny", "robots_unavailable_fail_closed");
    }
    if body_truncated {
        return empty_decision("deny", "robots_body_truncated_fail_closed");
    }
    let Some(rule) = best_rule(&parsed.rules) else {
        return empty_decision("allow", "no_matching_disallow_rule");
    };
    let decision = if rule.directive == "allow" {
        "allow"
    } else {
        "deny"
    };
    RobotsDecision {
        decision,
        reason: "matched_robots_rule",
        rule: json!({
            "directive": rule.directive,
            "path": rule.pattern,
            "line": rule.line,
            "matchLength": rule_match_length(&rule.pattern)
        }),
    }
}

fn empty_decision(decision: &'static str, reason: &'static str) -> RobotsDecision {
    RobotsDecision {
        decision,
        reason,
        rule: Value::Null,
    }
}

fn best_rule(rules: &[RobotsRule]) -> Option<&RobotsRule> {
    rules.iter().max_by(|left, right| {
        rule_match_length(&left.pattern)
            .cmp(&rule_match_length(&right.pattern))
            .then_with(|| (left.directive == "allow").cmp(&(right.directive == "allow")))
    })
}

fn user_agent_specificity(user_agent: &str, candidate: &str) -> Option<usize> {
    let candidate = candidate.trim();
    if candidate == "*" {
        Some(0)
    } else if !candidate.is_empty() && user_agent.contains(candidate) {
        Some(candidate.len())
    } else {
        None
    }
}

fn rule_matches(pattern: &str, target_path: &str) -> bool {
    if pattern.is_empty() {
        return false;
    }
    let anchored = pattern.ends_with('$');
    let pattern = pattern.trim_end_matches('$');
    if !pattern.contains('*') {
        return if anchored {
            target_path == pattern
        } else {
            target_path.starts_with(pattern)
        };
    }
    let mut remainder = target_path;
    for (index, part) in pattern.split('*').enumerate() {
        if part.is_empty() {
            continue;
        }
        if index == 0 {
            if !remainder.starts_with(part) {
                return false;
            }
            remainder = &remainder[part.len()..];
        } else if let Some(offset) = remainder.find(part) {
            remainder = &remainder[offset + part.len()..];
        } else {
            return false;
        }
    }
    !anchored || remainder.is_empty()
}

fn rule_match_length(pattern: &str) -> usize {
    pattern
        .trim_end_matches('$')
        .chars()
        .filter(|ch| *ch != '*')
        .count()
}
