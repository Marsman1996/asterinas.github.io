---
layout: post
title: "Proving Soundness for Unsafe Rust: Lessons from a Kernel"
date: 2026-04-01 09:00:00 +0800
author: [Asterinas Team, CertiK]
categories: [formal-verification, rust, kernel]
tags: [unsafe, soundness, verus, ostd, asterinas]
updated: 2026-04-01 11:35:44
---

*(Foreword: This post summarizes our progress in verifying OSTD. This work is carried out in collaboration with [CertiK](https://www.certik.com/).)*

Rust's `unsafe` mechanism is an escape hatch for low-level code, and in kernel development, that hatch is unavoidable. Kernels must manage raw physical addresses, manipulate hardware page tables, and execute direct memory access. These operations inherently violate Rust's high-level abstractions, like strict ownership and memory safety, which are the exact features that make the language so valuable.

Carefully encapsulating this `unsafe` code is the standard way to bridge the gap, but an abstraction is only as good as your confidence in it. The challenge is this: can you actually *trust* that the safe API built around your `unsafe` core is perfectly sound for every possible caller, in every possible state?

**[Asterinas](https://github.com/asterinas/asterinas)** is a Linux ABI-compatible, general purpose OS kernel written entirely in Rust. It uses a novel **[framekernel architecture](https://asterinas.github.io/book/kernel/the-framekernel-architecture.html)** that enforces a strict separation between *mechanism* and *policy*:

- **Mechanism:** The Operating System Standard Library ([OSTD](https://asterinas.github.io/book/ostd/index.html)) handles the raw, dangerous primitives: physical memory management, page tables, and hardware configuration. These are the operations that cannot be implemented in safe Rust.
- **Policy:** Everything built on top of OSTD, such as scheduling, file systems, and network protocols, dictates system behavior. This layer is implemented entirely in *safe Rust*, strictly enforced by `#![deny(unsafe_code)]` in every crate outside OSTD.

This architecture gives kernel developers access to the powerful abstractions and guarantees of safe Rust. It also makes OSTD's soundness incredibly load-bearing. OSTD consists of about 15,000 lines of mechanism code. Sitting above it are over 100,000 lines of safe policy code, written under the guarantees of Rust's high-level features. This massive upper layer automatically inherits Rust's guarantees if and only if OSTD's public API is sound. A bug in OSTD isn't just a localized issue; it compromises the safety guarantees of the entire rest of the kernel.

When a small piece of code has an outsized impact on system reliability, it is the perfect candidate for **formal verification** (FV). FV uses mathematical logic to create machine-checked proofs that guarantee the code behaves exactly as intended.

While writing these specifications and proofs requires significant upfront effort, the payoff is absolute certainty with zero runtime overhead. And as we will show, that *effort is now far more manageable than it used to be*.

A year ago, *our [Phase I](https://asterinas.github.io/2025/02/13/towards-practical-formal-verification-for-a-general-purpose-os-in-rust.html) groundwork* successfully verified isolated functions within the memory management (`mm`) module. While meaningful, these proofs were localized.

**This post marks Phase II.** Not only have we verified *more* functions' individual behavior, but we have successfully proven that the public API of the entire `mm` module module is **sound**.

## Proving Encapsulation of Unsafe Rust

Rust developers idiomatically manage `unsafe` code via the **"Tootsie Pop" model** [^1]. An unsafe library has a small, meticulously audited `unsafe` "core," surrounded by the "shell" of safe public interfaces. Each call from the shell to the core is protected by '`// SAFETY: ...`' comments where the developers promise that the call won't trigger undefined behavior.

[^1]: The term originates from Niko Matsakis' 2016 post [*"The Tootsie Pop Model for Unsafe Code"*](https://smallcultfollowing.com/babysteps/blog/2016/05/27/the-tootsie-pop-model-for-unsafe-code/).

<object
  type="image/svg+xml"
  data="/assets/images/tootsie_pop.svg"
  alt="The Tootsie Pop model"
  style="max-width: 800px; width: 100%; height: auto;">
  The Tootsie Pop model
</object>

Even if those comments are very detailed (and frequently they are not) they cannot possibly give a sufficiently rigorous analysis of every possible state in which the call might occur. Verification can. Here's how.

### Methodology of the Verification

Our verification tool of choice is [Verus](https://github.com/verus-lang/verus), which integrates directly with the Rust language. Verus code is Rust code, with additional constructs that allow us to annotate functions with preconditions (boolean formulae that must be true in order to safely call the function) and postconditions (which we would like to prove to hold when the function returns). The Verus compiler converts the pre- and postconditions of each function's into constraints in a satisfiability problem and feeds the result to an SMT solver to exhaustively check whether the postconditions hold.

For complex verification, Verus also allows us to add *ghost state* that exists only during the verification. Because ghost variables are not compiled into executable code, they have no performance impact. They are only used to instrument the code to make information about the broader system legible to the verifier. For example, Verus' pointer libraries provide a ghost [`PointsTo<T>`](https://verus-lang.github.io/verus/verusdoc/vstd/simple_pptr/struct.PointsTo.html) type which encodes the current state of a piece of raw memory containing an object of type `T`. A `PointsTo` can only be constructed and modified through [*valid pointer operations*](https://verus-lang.github.io/verus/verusdoc/vstd/simple_pptr/struct.PPtr.html#example), so its existence provides the "witness" for Verus that the current state of an object in memory is valid.

We define our own ghost types that track parts of the system state that are invisible to any given function. A page table is a tree of nodes and their entries, so a [`PageTableOwner`](https://asterinas.github.io/vostd/ostd/specs/mm/page_table/struct.PageTableOwner.html) is a tree of [`EntryOwner`](https://asterinas.github.io/vostd/ostd/specs/mm/page_table/node/entry_owners/struct.EntryOwner.html) and [`NodeOwner`](https://asterinas.github.io/vostd/ostd/specs/mm/page_table/node/owners/struct.NodeOwner.html) ghost objects, each describing the current state of a concrete object in the system without the need for executable code to access it.

To take a concrete example from the function `Entry::replace`, which overwrites a page table entry. In non-verified code, the function makes three promises when it calls the unsafe [`write_pte`](https://asterinas.github.io/vostd/ostd/mm/page_table/struct.PageTableGuard.html#method.write_pte):

```rust-verus
// SAFETY:
// 1. The index is within the bounds.
// 2. The new PTE is a valid child whose level matches the 
//    current page table node.
// 3. The ownership of the child is transferred to the page table node.
unsafe { self.node.write_pte(self.idx, self.pte) };
```

In Verus, these promises can be made explicit preconditions of `write_pte` as below, which takes an additional ghost argument of type `NodeOwner`. `Tracked` here is a kind of ghost object that obeys the borrow checker.

```rust-verus
#[verus_spec(with Tracked(owner): Tracked<&mut NodeOwner<C>>)]
fn write_pte(&mut self, idx: usize, pte: C::E)
    requires
      idx < NR_ENTRIES, // Promise 1
      old(self).inner.inner@.invariants(*old(owner)) // Subsumes 2
    ensures
      owner.inv(), // Used in caller to prove 3
      owner.children.value() == old(owner).children.value().update[idx, pte],
      ...
```

Now all calls to `write_pte` from anywhere in the verified codebase will have these `requires` conditions checked at compile time. At the same time, `write_pte` has obligations of its own (`ensures`). It maintains a weakened invariant, and sets the value of memory at the designated index to match the parameter.

<object
  type="image/svg+xml"
  data="/assets/images/write_pte.svg"
  alt="write_pte"
  style="max-width: 700px; width: 100%; height: auto;">
  write_pte() function specification
</object>

In addition, the postconditions of `write_pte` allow its caller `replace` to satisfy its own obligations, and on down the call chain. So, function-level specifications are *vertically composed* as a matter of Verus' fundamental design.

<object
  type="image/svg+xml"
  data="/assets/images/soundness_correctness.svg"
  alt="Soundness and Correctness"
  style="max-width: 800px; width: 100%; height: auto;">
  Soundness and Correctness
</object>

Properties of this kind, relating a function's inputs to its outputs in a vertical composition between callers and callees, are commonly called *correctness* properties. Soundness and correctness are deeply intertwined. Even if our goal is not necessarily to prove correctness for the entire system, proving *anything* about higher level functions depends on the correctness of lower level functions. In this case, `Entry::replace` is called by `CursorMut::replace_cur_entry`, which is called by [`CursorMut::map`](https://asterinas.github.io/vostd/ostd/mm/vm_space/struct.CursorMut.html#method.map). The soundness proof for `map` depends on this entire chain of logic. Because lower-level proofs are "consumed" by higher-level ones, we are motivated to make their specifications as precise as possible.

In short, we describe the overall system in terms of logical state, and specify how that state is allowed to change during execution. Then, Verus checks that our specifications hold through mathematical deduction. These individual function specifications, combined across the entire system, must support our ultimate claim of soundness.

What does that mean?

### Defining Soundness Formally

"Soundness" is a contract between a library and its caller. As long as the caller does not exhibit UB, the library will not either. The caller is otherwise allowed to do anything it wants! Even if the caller's behavior is nonsensical, the library needs to respond with a well-defined result. In this case, the caller is assumed to be written in safe Rust, so it will satisfy its end of the bargain by definition.

Let's call the caller $C$, and represent the caller linking with OSTD using the $\bowtie$ symbol, creating a whole program $C \bowtie \mathit{OSTD}$. We can think of the result of executing that program once as *trace* of interactions between the two components: a possibly infinite sequence of state transitions. We write $C \bowtie \mathit{OSTD} \rightsquigarrow t$ to mean that the trace $t$ can be produced by $C$ linked with OSTD.

To sum up soundness in a single formula:

$$
\forall ~ C ~ t. ~ \textnormal{safe}(C) \wedge C \bowtie \mathit{OSTD} \rightsquigarrow t \Rightarrow \mathbf{well\_defined}(t)
$$

Without getting into the details of how a trace is constructed, it encodes three possibilities:

- the program might run forever - $\mathbf{infinite}(t)$,
- it might terminate - $\mathbf{terminates}(t)$,
- or it might get *stuck* - $\mathbf{stuck}(t)$.

Stuckness means that the Rust abstract machine has gotten into a state from which there is no defined way to continue, in other words, *UB*. We call a trace *well-defined*, written $\mathbf{well\\_defined}(t)$, if it avoids this third outcome:

$$
\mathbf{well\_defined}(t) \triangleq \mathbf{infinite}(t) \lor \mathbf{terminates}(t)
$$

and naturally,

$$
\mathbf{well\_defined}(t) \iff \neg \mathbf{stuck}(t)
$$

Let's examine the implications of this formulation:

- We quantify over all possible callers, which is much harder than verifying a single program. The only obligation we impose on $C$ is $\mathbf{safe}(C)$: that the caller is well-typed under Rust's type system and contains no `unsafe` blocks.
- We quantify over all traces; in practical terms, this means that $C$ can call into OSTD functions in any order.
- We aren't looking for individual cases of UB, we are constructively proving that there is some defined behavior for any $C$, which inherently rules out UB.

### Time to Unwind

The first step to proving the theorem above is breaking down a trace into individual calls, via an *unwinding theorem* [^2]. This strategy has three steps:

1. **Define the rules:** Identify the state invariants required to guarantee defined behavior.
2. **Prove the start:** Prove these rules hold true when the system initializes.
3. **Prove the transitions:** Prove that every single public API function *preserves* these rules. Assuming they hold when the function is called, they must still hold when it returns.

[^2]: We borrow the term from Goguen & Meseguer's [unwinding theorem for noninterference](https://doi.org/10.1109/SP.1984.10019), which shares the same key insight: a daunting global property over all possible traces can be unwound into a finite set of local, per-step obligations. Once those local obligations are discharged, the global property follows for free, for every possible execution, no matter how long. In our usage, the global property is soundness and the local obligation is that every public API function preserves the system invariants.

By induction, if the system starts in a valid state, and every possible API call preserves that valid state, then the state is always valid between calls. This allows us to break the verification of a system-level property into a series of *correctness* proofs. The invariants are the glue that hold them together in a *horizontal composition*.

<object
  type="image/svg+xml"
  data="/assets/images/horizontal.svg"
  alt="Soundness as Horizontal Composition"
  style="max-width: 800px; width: 100%; height: auto;">
  Soundness as Horizontal Composition
</object>

To see this in practice, let's look at `metaregion_sound`, the most critical system invariant in the memory management (`mm`) module. This rule asserts that the associated page table entry matches the global physical memory records ([`MetaRegionOwners`](https://asterinas.github.io/vostd/ostd/specs/mm/frame/meta_region_owners/struct.MetaRegionOwners.html)), which live in a special metadata region.

```rust-verus
impl<C: PageTableConfig> EntryOwner<C> {

pub open spec fn metaregion_sound(self, regions: MetaRegionOwners) -> bool {
        if self.is_node() {
            let idx = frame_to_index(self.meta_slot_paddr().unwrap());
            &&& regions.ref_count(idx) != REF_COUNT_UNUSED
            &&& 0 < regions.ref_count(idx) <= REF_COUNT_MAX
            &&& regions.slots[idx].value().wf(regions.slot_owners[idx])
            &&& regions.slot_owners[idx].paths_in_pt == set![self.path]
            &&& self.node.unwrap().metaregion_sound_node(regions)
            ... // a few clauses omitted
        } else if self.is_frame() {
            let idx = frame_to_index(self.meta_slot_paddr().unwrap());
            &&& regions.slots[idx].value().wf(regions.slot_owners[idx])
            &&& regions.slot_owners[idx].usage != PageUsage::MMIO ==> {
                &&& regions.ref_count(idx) != REF_COUNT_UNUSED
                &&& 0 < regions.ref_count(idx) <= REF_COUNT_MAX
            }
            &&& regions.slot_owners[idx].paths_in_pt.contains(self.path)
            &&& regions.slot_owners[idx].usage != PageUsage::PageTable
            &&& self.frame_sub_pages_valid(regions)
            ... // a few clauses omitted
        } else {
            true
        }
}
... // more specs and proofs omitted
}
```

The [`paths_if_in_pt`](https://asterinas.github.io/vostd/ostd/specs/mm/frame/meta_owners/struct.MetaSlotOwner.html#structfield.path_if_in_pt) clause, present only in the `is_node()` branch, ensures that each page table **node** corresponds to exactly one position in the tree. The equivalent condition for mapped frames (`.is_frame()`) is weaker, only requiring that the current entry's path be contained in the set. Because the same physical frame may legitimately be mapped to multiple virtual addresses simultaneously, this does not cause UB from the kernel's perspective. Soundness proofs do not let us place obligations on the caller; our model needs to be flexible enough to specify even erroneous (but well-defined) calls.

Collectively, system invariants like metaregion_sound define the strict rules that every public API must preserve. This is exactly why verifying isolated functions is insufficient. Even if individual functions are completely correct in a vacuum, any unverified code touching the same data structures could silently violate these shared invariants, thus collapsing the entire system's proof. To guarantee true soundness, the module must be verified as a cohesive whole. We check the final soundness property by embedding the specifications of verified functions in a state machine, which may take arbitrary steps using the specification of any function in any order.

## Does the Methodology Scale?

A verification approach is only practical if it can be executed without a massive, multi-year engineering effort. Here is the evidence that our methodology not only works in theory but actually scales in practice.

We began a year ago with a proof of concept, verifying selected properties of individual functions but leaving the bulk of the code unverified. After taking lessons from that phase and scaling up our efforts, in just over a year we have expanded to cover the entire virtual memory subsystem of the memory management (`mm`) module, from raw physical frame allocation at the bottom to virtual address space mapping at the top. Recall that horizontal composition is vital for proving soundness: verifying an entire subsystem is much more valuable than disconnected functions. Meanwhile, a parallel project called [CortenMM](https://dl.acm.org/doi/10.1145/3731569.3764836) has verified the complex concurrent correctness of the page table's fine-grained locking, and has been published in SOSP '25.

As a proxy for cost, historically, formal verification requires about 20 lines of mathematical proof for every 1 line of code (a 1:20 ratio). This immense cost has blocked widespread industrial adoption. **We reduced this ratio to roughly 1:5.**

This efficiency comes from two factors: Verus’ automated SMT solver effortlessly handles routine mathematical obligations in the background, and OSTD’s tightly scoped, modular architecture prevents proof complexity from spiraling out of control.

Advances in AI help us scale even faster. Because proof annotations often follow predictable patterns derived from the system model, AI can be very effective in helping the SMT solver handle proofs that previously would require human guidance. To this end we built **KVerus**, an AI-assisted tool that automatically generates a growing fraction of our proofs. Crucially, AI assistance accelerates the writing process but does not alter the trustworthiness of the results. Every single proof generated by KVerus is strictly checked and validated by Verus's mathematical solver. AI frees our engineers to focus on the big picture questions: specifications, system models, and proof strategy.

Another common critique of formal verification is that proofs quickly become outdated as code evolves. Verification projects are usually static, pinned to a particular version of the target software. We began our verification on OSTD v0.15 and are currently tracking v0.16.0. Thanks to our modular invariant structure and KVerus's ability to help repair proofs, updating our verification alongside codebase changes has proven quite manageable. Our ultimate goal is continuous verification: updating proofs in the same pull request as the code they cover.

## From Promise to Proof

To recap where we stand: we have verified soundness of a significant subset of OSTD, covering virtual memory management libraries from physical frames up to virtual address spaces. The diagram below shows the structure of the verified subset, with unverified `mm` modules to the left and the rest of OSTD to the right. Compare to last year's proof-of-concept: where we had picked out a handful of functions from each module, now we can simply list the modules. In general any function on a call path from the API functions is verified, save a few that are axiomatized as part of the trusted computing base.

Outside of CortenMM we verify the system as a sequential program, with further concurrent verification a future goal. We are currently expanding into verifying the synchronization primitives in `sync`.

<object
  type="image/svg+xml"
  data="/assets/images/subset.svg"
  alt="Verified Subset of OSTD"
  style="max-width: 800px; width: 100%; height: auto;">
  Verified Subset of OSTD
</object>

We verified part of a kernel with this approach, but very little of it is kernel-specific. Any Rust project relying on a complex `unsafe` core faces similar challenges, and can be approached in a similar way:

- **Formalize the unseen:** You cannot prove what you cannot describe. Build a model in ghost state of the logical structure of your system.
- **Anchor the foundation:** High-level promises are only as strong as their lowest-level implementations. Axiomatize mechanisms below the Rust level carefully, and prove correctness of your lower level code.
- **Build a fence:**  Rather than trying to anticipate every possible interaction, establish invariants that constrain the chaos and provide a reliable precondition for all API functions.
- **Assert the positive:** Rather than endlessly chasing the infinite ways a system might fail, prove that it does *something.*

And that's how you prove soundness.
