---
layout: post
title: "Proving Soundness for Unsafe Rust: Lessons from a Kernel"
date: 2026-03-30 09:00:00 +0800
author: [Asterinas Team, CertiK]
categories: [formal-verification, rust, kernel]
tags: [unsafe, soundness, verus, ostd, asterinas]
updated: 2026-03-30 11:35:44
---

*(Foreword: This post summarizes our progress in verifying OSTD. This work is carried out in collaboration with [CertiK](https://www.certik.com/).)*

Rust's `unsafe` mechanism helps it bridge the gap between its powerful high-level features and the occasional need for low-level code. Such low-level code is inherently necessary in kernel programming. At the lowest levels, kernel code must handle raw physical addresses and write directly to memory, forcing the code to break high-level abstractions. But for a component as critical as a kernel, the high-level features are valuable in helping programmers write cleaner, safer code.

**[Asterinas](https://github.com/asterinas/asterinas)** is a Linux ABI-compatible OS kernel written entirely in Rust. It uses a novel **[framekernel architecture](https://asterinas.github.io/book/kernel/the-framekernel-architecture.html)** that enforces a strict separation between *mechanism* and *policy*:

- **Mechanism:** The Operating System Standard Library ([OSTD](https://asterinas.github.io/book/ostd/index.html)) handles the raw, dangerous primitives: physical memory management, page tables, and hardware configuration. These are the operations that cannot be implemented in safe Rust.
- **Policy:** Everything built on top of OSTD, such as scheduling, file systems, and network protocols, dictates system behavior. This layer is implemented entirely in *safe Rust*, strictly enforced by `#![deny(unsafe_code)]` in every crate outside OSTD.

This architecture gives kernel developers access to the powerful abstractions and guarantees of safe Rust. It also makes OSTD's soundness incredibly load-bearing. OSTD consists of about 15,000 lines of mechanism code. Sitting above it are over 100,000 lines of safe policy code, written under the guarantees of Rust's high-level features. This massive upper layer automatically inherits Rust's guarantees if and only if OSTD's public API is sound. A bug in OSTD isn't just a localized issue; it is a crack in the foundation that every other crate relies on.

A small piece of code with an outsized impact on system reliability is a strong candidate for *formal verification* (FV). FV uses mathematical logic to construct machine-checked proofs of the validity of assertions about the code. Constructing the specifications to be proven and guiding the system toward the proof is a lot of effort, but when it is done it produces a very high degree of assurance with no runtime overhead. In this case we use **[Verus](https://github.com/verus-lang/verus)**, a Rust dialect with source-code annotations that integrate with an SMT solver.

A year ago, [our Phase I groundwork](https://asterinas.github.io/2025/02/13/towards-practical-formal-verification-for-a-general-purpose-os-in-rust.html) successfully verified isolated functions within the memory management (`mm`) module. While meaningful, these proofs were localized. 

**This post marks Phase II.** Not only have we verified *more* functions' individual behavior, but we have successfully proven that the public API of the entire `mm` module is **sound**.

## Proving Encapsulating of Unsafe Rust

Rust developers generally manage `unsafe` code via **"Tootsie Pop" model**. An unsafe library has a small, meticulously audited `unsafe` "core," surrounded by the "shell" of safe public interfaces. Each call from the shell to the core is protected by '`// SAFETY: ...`' comments where the developers promise that the call won't trigger undefined behavior.

<img src="/assets/images/tootsie_pop.png" alt="The Tootsie Pop model" style="width: 80%;" />

Even if those comments are very detailed (and frequently they are not) they cannot possibly give a sufficiently rigorous analysis of every possible state in which the call might occur. Verification can. Here's how.

### Verus

Our verification tool of choice is Verus, which integrates directly with the Rust language. Verus code is Rust code, with additional constructs that allow us to annotate functions with preconditions (boolean formulae that must be true in order to safely call the function) and postconditions (which we would like to prove to hold when the function returns). The Verus compiler converts the pre- and postconditions of each functions into constraints in a satisfiability problem and feeds the result to an SMT solver to exhaustively check whether the postconditions hold.

For complex verification, Verus also allows us to add *ghost state* that exists only during the verification process. Because ghost variables are not compiled into executable code, they have no performance impact, but they can be used to instrument the code to make information about the broader system legible to the verifier. For example, Verus' pointer libraries provide a ghost `PointsTo<T>` type which encodes the current state of a piece of raw memory containing an object of type `T`. A `PointsTo` can only be constructed and modified through valid pointer operations, so its existence provides the "witness" for Verus that the current state of an object in memory is valid. We also define our own ghost types that track parts of the system state that are invisible to any given function. A page table is a tree of individual nodes and their entries, so a `PageTableOwner` is a tree of `EntryOwner` ghost objects, each describing the current state of a concrete object in the system without the need for executable code to access it.

TODO: small example connecting a "SAFETY" comment to a specification.

In short, we describe the overall system in terms of imaginary state, specify how that state is allowed to change during execution, and help the solver prove that all real executions match the specifications. So what is the specification here?

### Defining Soundness Formally

"Soundness" is a contract between a library and its caller. As long as the caller does not exhibit UB, the library will not either. The caller is otherwise allowed to do anything it wants! Even if the caller's behavior is nonsensical, the library needs to respond with a well-defined result. In this case, the caller is assumed to be written in safe Rust, so it will satisfy its end of the bargain by definition.

Let's call the caller $C$, and represent the caller linking with OSTD using the $\bowtie$ symbol, creating a whole program $C \bowtie \mathit{OSTD}$. We can think of the result of executing that program once as *trace* of interactions between the two components: a possibly infinite sequence of state transitions. We write $C \bowtie \mathit{OSTD} \rightsquigarrow t$ to mean that the trace $t$ can be produced by $C$ linked with OSTD. Without getting into the details of how a trace is constructed, it encodes three possibilities: the program might run forever, it might terminate, or it might get *stuck*. Stuckness means that the Rust abstract machine has gotten into a state from which there is no defined way to continue—in other words, UB.

To sum up soundness in a single formula:

$$
\forall ~ C ~ t. ~ \textnormal{safe}(C) \Rightarrow C \bowtie \mathit{OSTD} \rightsquigarrow t \Rightarrow \mathbf{infinite}(t) \lor \mathbf{terminates}(t)
$$

Let's examine the implications of this formulation:

- We quantify over all possible callers, which is much harder than verifying a single program. We cannot impose any obligation on $C$.
- We quantify over all traces; in practical terms, this means that $C$ can call into OSTD in any order.
- We aren't looking for individual cases of UB, we are constructively proving that there is some defined behavior for any $C$, which inherently rules out UB[^2].

[^2] For more on this principle, see Appel, Program Logics for Certified Compilers.

### Time to Unwind

The first step to proving the theorem above is breaking down a trace into individual calls, via an *unwinding theorem*. This strategy has three steps:

1. **Define the rules:** Identify the state invariants required to guarantee defined behavior.
2. **Prove the start:** Prove these rules hold true when the system initializes.
3. **Prove the transitions:** Prove that every single public API function *preserves* these rules, assuming they hold when the function is called, they must still hold when it returns.

By induction, if the system starts in a valid state, and every possible API call preserves that valid state, then the state is always valid between calls. This allows us to break the verification of a system-level property into a series of *correctness* proofs. The invariants are the glue that hold them together in a horizontal composition.

To see this in practice, look at `metaregion_sound`, the most critical system invariant in the memory management (`mm`) module. This rule asserts that the associated page table entry matches the global physical memory records (`MetaRegionOwners`).

```rust
impl<C: PageTableConfig> EntryOwner<C> {
    pub open spec fn metaregion_sound(self, regions: MetaRegionOwners) -> bool {
        if self.is_node() {
            let idx = frame_to_index(self.meta_slot_paddr().unwrap());
            &&& regions.slot_owners[idx].inner_perms.ref_count.value() != REF_COUNT_UNUSED
            &&& regions.slot_owners[idx].raw_count == self.expected_raw_count()
            &&& regions.slot_owners[idx].self_addr == self.node.unwrap().meta_perm.addr()
            &&& self.node.unwrap().meta_perm.points_to.value().wf(regions.slot_owners[idx])
            // Node path tracking: ensures no two tree nodes share the same slot index.
            &&& regions.slot_owners[idx].path_if_in_pt == Some(self.path)
        } else if self.is_frame() {
            let idx = frame_to_index(self.meta_slot_paddr().unwrap());
            &&& regions.slots.contains_key(idx)
            &&& regions.slots[idx].addr() == meta_addr(idx)
            &&& regions.slots[idx].is_init()
            &&& regions.slots[idx].value().wf(regions.slot_owners[idx])
            &&& regions.slot_owners[idx].inner_perms.ref_count.value() != REF_COUNT_UNUSED
        } else {
            true
        }
    }
}
```

 The `path_if_in_pt` clause ensures that page table nodes are unique and correspond to exactly one position in the tree. Note that no such clause exists for mapped frames. While mapping a frame to multiple positions in a userspace page table might have unexpected results, it does not cause undefined behavior from the kernel's perspective.

Intuitively, it may be surprising that a soundness proof requires proving correctness as well, if only incompletely. But the two kinds of properties are not as distinct as they seem on the surface. While proving soundness in theory only requires showing that each function's behavior has *some* definition, in practice, verifying a higher-level function requires us to be much more precise in specifying the lower-level functions it calls. The specification of API functions that are solely called from outside of OSTD can be looser, but must be at least precise enough to maintain the invariants.

<img src="/assets/images/soundness_correctness.png" alt="Soundness and Correctness" style="width: 65%;" />

## Does the Methodology Scale?

A verification approach is only practical if it can be executed without a massive, multi-year engineering effort. Here is the evidence that our methodology not only works in theory but actually scales in practice.

We began a year ago with a proof of concept, verifying selected properties of individual functions but leaving the bulk of the code unverified. After taking lessons from that phase and scaling up our efforts, in just over a year we have expanded to cover the entire virtual memory subsystem of the memory management (`mm`) module, from raw physical frame allocation at the bottom to virtual address space mapping at the top. Recall that horizontal composition is vital for proving soundness: verifying an entire subsystem is much more valuable than disconnected functions. Meanwhile, a parallel effort called CortenMM has verified the complex concurrent correctness of the page table's fine-grained locking. (TODO: link CortenMM post).

As a proxy for cost, historically, formal verification requires about 20 lines of mathematical proof for every 1 line of code (a 1:20 ratio). This immense cost has blocked widespread industrial adoption. **We reduced this ratio to below 1:4.** This efficiency comes from two factors: Verus’ automated SMT solver effortlessly handles routine mathematical obligations in the background, and OSTD’s tightly scoped, modular architecture prevents proof complexity from spiraling out of control. Advances in AI help us scale even faster. Because proof annotations often follow predictable patterns derived from the system model, AI can be very effective in helping the SMT solver handle proofs that previously would require human guidance. To this end we built **KVerus**, an AI-assisted tool that automatically generates a growing fraction of our proofs. Crucially, AI assistance accelerates the writing process but does not alter the trustworthiness of the results. Every single proof generated by KVerus is strictly checked and validated by Verus's mathematical solver. AI frees our engineers to focus on the big picture questions: specifications, system models, and proof strategy.

Another common critique of formal verification is that proofs quickly become outdated as code evolves. Verification projects are usually static, pinned to a particular version of the target software. We began our verification on OSTD v0.15 and are currently tracking v0.16.2. Thanks to our modular invariant structure and KVerus's ability to help repair proofs, updating our verification alongside codebase changes has proven quite manageable. Our ultimate goal is continuous verification: updating proofs in the exact same pull request as the code they cover.

## From Promise to Proof

We verified part of a kernel with this approach, but very little of it is kernel-specific. Any Rust project relying on a complex `unsafe` core faces similar challenges, and can be approached in a similar way:

- **Formalize the unseen:** You cannot prove what you cannot describe. Build a model in ghost state of the logical structure of your system.
- **Anchor the foundation:** High-level promises are only as strong as their lowest-level implementations. Axiomatize mechanisms below the Rust level carefully, and prove correctness of your lower level code.
- **Build a fence:**  Rather than trying to anticipate every possible interaction, establish invariants that constrain the chaos and provide a reliable precondition for all API functions.
- **Assert the positive:** Rather than endlessly chasing the infinite ways a system might fail, prove that it does *something.*

And that's how you prove soundness.