# frozen_string_literal: true

# Custom Rouge lexer for Verus-extended Rust (Jekyll highlights fenced code via Rouge).
# After changing this file, clear Jekyll’s cache or old highlighted HTML may persist:
#   rm -rf .jekyll-cache _site && bundle exec jekyll build
# Stock Rust :attribute state does not tokenize < > & * @ inside attributes, which
# produced Error tokens (.err) for generics in e.g. #[verus_spec(... Tracked<&mut T>)].
# Use the full `rouge` entrypoint so RegexLexer and the base Rust lexer are loaded
# (a bare `require "rouge/lexers/rust"` runs too early under Jekyll and raises NameError).
require "rouge"

module Rouge
  module Lexers
    class RustVerus < Rust
      title "Rust (Verus)"
      desc "Rust with Verus verification annotations"
      tag "rust-verus"
      aliases "verus", "rust_verus"

      VERUS_KEYWORDS = %w(
        assume assume_specification axiom broadcast closed decreases default_ensures
        ensures exec exists final forall ghost global has implies invariant
        invariant_except_break is matches no_unwind old open opens_invariants proof
        recommends requires returns spec tracked trigger uninterp via when
        verus_spec
      ).freeze

      prepend :attribute do
        # Stock lexer labels every identifier inside #[...] as Name::Decorator, so the
        # Verus attribute macro name looked the same as its arguments. Highlight it
        # like a keyword so it reads as the active macro.
        rule %r/\bverus_spec\b/, Keyword
        # Type / constructor: Tracked<&mut T> or Tracked(owner): … inside the attribute.
        rule %r/\bTracked(?=\s*[<(])/, Name::Class
        rule %r/[<>*&@]/, Name::Decorator
      end

      prepend :root do
        # PascalCase ghost wrapper as type when generic args follow.
        rule %r/\bTracked(?=\s*<)/, Name::Class
        # Verus `tracked(...)` mode / calls — not the same token as `Tracked<...>`.
        rule %r/\btracked(?=\s*[(])/, Name::Function
        rule %r/\b(?:#{VERUS_KEYWORDS.join('|')})\b/, Keyword
      end
    end
  end
end
