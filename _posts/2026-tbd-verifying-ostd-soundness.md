# Verifying OSTD soundness

*(Foreword: This post summarizes our progress in verifying OSTD and highlights key results from our research papers. This work is carried out in collaboration with [CertiK](https://www.certik.com/).)*

You can trust Rust. Millions of developers sleep soundly on the promise that Rust is safer than other systems-level programming languages. That's why we chose it for Asterinas -- if any system needs to be trusted, it's a kernel. Our framekernel architecture confines all unsafe code to OSTD, a minimal 15,000-line trusted core. If OSTD is unsound, the entire 100,000-line kernel is unsafe as well.

So we had better be really certain that OSTD is actually well-encapsulated! And when we need certainty, we turn to formal verification.

A year ago, we reported our [initial results](https://asterinas.github.io/2025/02/13/towards-practical-formal-verification-for-a-general-purpose-os-in-rust.html) in verifying the `mm` module: a collection of functions from different components of the module, for each of which we verified specific safety concerns. Now we have expanded that effort to all components:

![Architecture of the formal verification components in the OSTD Memory Management subsystem](/assets/images/subset.png)

> Figure 1. Architecture of the formal verification components in the OSTD Memory Management subsystem

The key components are:

- The `frame` module, which tracks the metadata of frames in an unsafe array of metadata slots, and provides interfaces for creating and interacting with different kinds of frames
- The `page_table` module, which depends on `frame` to construct both internal nodes and frames to map into virtual memory
- The interconnected `vm_space` and `io` modules, which provide an interface for mapping frames into virtual memory and constructing readers and writers to operate on them

From the low-level foundation of `frame` to the "high-level" (for the kernel) abstraction of `vm_space` and `io`, we verify the Rust-soundness of the OSTD interface, as well as correctness properties of each component. (In `vm_space`, the soundness claim is weaker, because an ill-behaved caller can misconfigure userspace memory to cause UB, but that UB cannot affect kernel space.)

Besides the `mm` verification effort, we have published a paper on concurrent verification of our performant page table locking mechanism. Read more about that [here](https://dl.acm.org/doi/10.1145/3731569.3764836).

In this post, we will dig into how we define Rust soundness as a formal property, and how individual verified functions compose vertically and horizontally to prove that property, along with useful correctness properties, over this entire subset of OSTD.

---

## Proving Rust Soundness Positively

In `unsafe` Rust, the programmer is allowed to write code that may be nonsensical, and the Rust compiler only guarantees that a small subset of those possible programs will have any particular behavior. Code that does not fit into that subset is considered to have undefined behavior (UB). When such code is linked against safe Rust, we can no longer be confident that the safe code will behave as expected, because undefined behavior in the unsafe code could cause errors to crop up at any point in execution. The only way to ensure that this doesn't happen is to prove that the Rust semantics are sound in the context of this specific unsafe code.

Rust Soundness is the property of such a library that it is never responsible for UB. In Asterinas, since OSTD is the only library that is allowed to contain unsafe Rust, we can be more precise: when linked against any safe caller, a sound library never encounters **UB**.

There is a saying in the formal methods community, generally attributed to Andrew Appel, of the [Verified Software Toolkit](https://vst.cs.princeton.edu/):

> *The best way to show that a program has no undefined behavior is to show that it has a particular defined behavior.*

The reason lies in the structure of language specifications construction: they are designed to express positive statements about defined programs, rather than negative statements about undefined ones. In Rust, especially, the exact range of what is considered UB is not fully established and may change between Rust versions, whereas a narrower sense of "behavior that is defined in unsafe code" remains more stable. Tools like [Miri](https://github.com/rust-lang/miri), which we [also use to check OSTD](https://asterinas.github.io/2025/06/04/kernel-memory-safety-mission-accomplished.html), do a remarkable job of detecting some classes of UB at runtime, but they can only explore the paths they actually execute. They cannot guarantee that the paths they didn't explore are clean.

> The most rigorous approach is to prove what the program *does*, not what it *doesn't*. Once you establish that a piece of code has a specific, defined behavior, the absence of UB follows as a consequence.

This reframing shifts the target entirely. Instead of asking "Does this code have UB?", we ask "What does this code do?" If we can answer the second question precisely and completely, the first is answered automatically. And we gain something else in return: *stability*.

**Enter: [Verus](https://github.com/verus-lang/verus).** Verus is a dialect of Rust intended for formal deductive verification of code. Unlike Rust, Verus has no distinction between safe and unsafe code. Instead, all operations that might cause **UB** in Rust (and many that are defined but might cause unexpected behavior, like integer arithmetic that could overflow or underflow) require the checker to construct a proof that their preconditions are satisfied.

Verus verifies proofs on a per-function basis, annotating each function with pre- and post-conditions that its SMT solver checks at every exit point. Many of these proofs are discharged automatically from the surrounding code: for instance, when `x` is `unsigned`,

```rust
if x > 0 { x - 1 } else { 0 }
```

requires no human intervention to prove the subtraction is safe. For operations the solver cannot resolve on its own, the user provides an explicit *witness*, a piece of ghost code that carries a logical ‘fact’ the compiler needs but discards after verification.

For memory accesses, this witness is a `PointsTo` object, encoding the fact that an address holds a particular value. This means that Verus code can reason explicitly about unsafe code that is still well-defined in the Rust memory model. In the Rust MM, writing through a pointer that was cast from an integer is valid if there is some known object in that location that previously had its address ‘exposed’, but it is incumbent on the programmer to ensure that this is the case, and that the object in question is always the one that was intended. In Verus reading and writing through any pointer requires an explicit proof that the target object exists, in the form of the `PointsTo` token. The programmer's job is to use ghost state to track the value of the tokens, much like the Rust programmer tracks objects in memory, but now with a verifier to check the work.

Verifying individual functions in isolation, however, is only the beginning. The real challenge lies in how those per-function specifications are composed across the entire codebase. As we will see, it is precisely this composition, both vertical across call stacks and horizontal across calling contexts, that allows local proof obligations to accumulate into a system-wide guarantee.

> **The key to effective verification is composing those specifications, both vertically and horizontally.**

### Vertical Composition: When Soundness Becomes Correctness

Function specifications are composed vertically, just like the functions themselves. This is straightforward enough, but it has an important implication for the kinds of specifications we prove. While proving soundness in theory only requires showing that each function's behavior has *a* definition, in practice, verifying higher-level functions requires us to be much more precise in specifying the lower-level functions it calls.

> **A caller's soundness depends on the correctness of its callees.**

So, as we prove that each function exhibits some defined behavior, we are incentivized to make those specifications as tight as possible. The page table module is illustrative. Proving the correctness of `Entry::replace`, that it modifies exactly one entry in a page table node and leaves the rest unchanged, is a prerequisite for proving both the soundness and the correctness of `page_table::CursorMut::replace_cur_entry`. The correctness proof of that function is, in turn, a prerequisite for proving the soundness of `page_table::CursorMut::map`. Each layer's proof assumptions *motivate* the precision of the correctness specs in the layers below, and validate the
assumptions of the ones above.

> **Correctness and soundness are not parallel goals. One supports the other as you move up the call stack.**

![Soundness and correctness as a vertical feedback loop](/assets/images/soundness-correctness.png)

> Figure 2. Soundness and correctness as a vertical feedback loop. *The soundness obligation of each caller motivates tighter correctness specs in its callees; those correctness specs in turn become the proof prerequisites that discharge the caller's soundness. Correctness at the bottom is soundness at the top.*

At the top of the stack, the **public API of OSTD**, we are no longer writing specs for other proofs to consume. This changes what a good specification looks like. Internal specs must track implementation details closely because they are consumed by other proofs. The consumer for an external spec is the reader, attempting to understand exactly what has been verified. For a human audience, the specifications should be more abstract, so that it is clear at a glance that they capture desirable properties of the system. And in being more abstract, they are also represented differently from the code they describe, meaning that if the original code is buggy, the specification is less likely to simply reproduce the bug.

> Descriptions of what a module *should* do, not of what it *happens* to do.

For instance, the specification for a linked list cursor is a pair of mathematical sequences, representing the whole list bifurcated by the cursor:

```rust
// Verus mathematical sequence model
pub ghost struct CursorModel {
    pub ghost fore: Seq<LinkModel>,
    pub ghost rear: Seq<LinkModel>,
    pub ghost list_model: LinkedListModel,
}
```

### Horizontal Composition: Invariants Against Adversarial Calls

> How do you prove soundness against a caller you do not have?

Rust Soundness is a property of a partial program. To prove it in its basic form, we would need to quantify over all possible calling contexts that might call into OSTD. That's an infinite set, not very tractable to go through one-by-one. And in the end, Verus will still be verifying the functions one at a time. The solution is to *unwind* the property. We can think of the whole program execution as a loop, like this:

![Horizontal composition via invariants](/assets/images/horizontal.png)

> Figure 3. Horizontal composition via invariants. *Left: an arbitrary safe-Rust caller may invoke any API function in any order, store returned object handles, and re-dispatch them at any later time, where OSTD must remain UB-free under all such sequences. Middle: equipping each API function with specs and proofs reduces this infinite-caller problem to a per-function obligation, assuming invariants hold on entry, proving they are preserved on exit. Right: since every call is an invariant-preserving step, any sequence of calls, however adversarial, is UB-free.*

The client calls into OSTD via a function or method, and eventually receives a result. It may do so in any order, with any parameters to the calls. And it can do *nearly* anything with the results that it receives. The one catch is that, being safe Rust, it cannot duplicate those objects. We need to compose the functions horizontally and show that calling them in any order produces defined results.

We collect the assumptions that our functions rely on into *invariants* --- properties of the overall system state, which must be preserved by every API function call.

One important invariant is the relation between `EntryOwner` (a piece of "ghost state" that tracks the contents of a page table entry) and the global state of the metadata region, the `MetaRegionOwners`. This `relate_region` predicate contains a number of assertions that must hold for entries that represent nodes in the page table: they must have a valid metadata slot, which must have a suitable reference count, and their location within the tree-structure of the page table must be correctly tracked by the proof state. `expected_raw_count` is either zero or one, depending on whether the entry is currently in-scope or has been "forgotten" and converted into a raw pointer to store in its parent node. Entries that directly map frames have a simpler invariant, and absent entries, none at all.

```rust
impl<C: PageTableConfig> EntryOwner<C> {
    pub open spec fn relate_region(self, regions: MetaRegionOwners) -> bool {
        if self.is_node() {
            let idx = frame_to_index(self.meta_slot_paddr().unwrap());
            &&& regions.slot_owners[idx].inner_perms.ref_count.value() != REF_COUNT_UNUSED
            &&& regions.slot_owners[idx].raw_count == self.expected_raw_count()
            &&& regions.slot_owners[idx].self_addr == self.node.unwrap().meta_perm.addr()
            &&& self.node.unwrap().meta_perm.points_to.value().wf(regions.slot_owners[idx])
            &&& regions.slot_owners[idx].path_if_in_pt is Some ==>
                regions.slot_owners[idx].path_if_in_pt.unwrap() == self.path
        } else if self.is_frame() {
            regions.slot_owners[frame_to_index(self.meta_slot_paddr().unwrap())].path_if_in_pt is Some
            ==>
              regions.slot_owners[frame_to_index(self.meta_slot_paddr().unwrap())].path_if_in_pt.unwrap() 
                == self.path
        } else {
            true
        }
    }
}
```

This invariant is mapped over every entry in the page table, and it is essential for proving such properties as "a given frame is not mapped multiple times in the same page table"--- if it were, one of the copies would have the wrong path.

*Invariant preservation* is the bridge between the local and the global: **every public API function must preserve the system invariants, and those invariants are jointly sufficient to guarantee defined behavior at every call site.** Any sequence of calls is a sequence of invariant-preserving steps. For any particular calling context, we could trace its calls and construct that sequence of steps, confident that they will all be defined, as **UB** has nowhere to enter.

On top of this foundation, our correctness proofs at the API boundary place additional constraints on the caller and, in return, prove more detailed specifications of the functions' behavior. All callers get defined behavior, and reasonable callers get correct behavior.

In the case of the higher-level `vm_space` module, the situation becomes more complicated. We cannot prove that there is no UB for any arbitrary caller, because `vm_space` exposes an interface for the caller to map and unmap frames for userspace, and so can cause UB within userspace memory by mapping frames incoherently. In this case, we can still prove that kernel memory remains sound, as it covers a separate range of virtual addresses that the caller cannot corrupt. In addition to this "weak soundness," we prove correctness properties of VM space given additional constraints on the caller, especially the constraint that it maintains coherent virtual memory mappings in userspace.

---

## Toward Practical Kernel Soundness

After more than a year of development, where does OSTD soundness stand? We have proven defined behavior for a significant subset of the `mm` module, as well as correctness properties. The CortenMM project has verified concurrent corrections of the page table's fine-grained locking mechanism. We are now expanding into the `sync` module for more concurrency verification. Documentation of the verified APIs is already available [online](https://asterinas.github.io/vostd/ostd/index.html), and it continues to grow.

> **Is verification cheap?**

No, but it is cheaper than ever before.

Formal verification has traditionally been expensive: much like in mathematics, the proof is often far longer than the statement it establishes.

Today, our code-to-proof ratio is below 1:4, significantly lower than the 1:20+ commonly seen in traditional theorem-prover developments. This improvement comes from the deductive design of Verus and the focused scope of OSTD as a TCB. Even better, our AI-assisted proof tool, KVerus, is already generating a noticeable portion of the proof code automatically, and we expect this share to keep growing.

Another major obstacle to practical verification systems is the challenge of maintaining the verification when updating the codebase. Through careful structuring of the verification process and with the help of KVerus, we are able to merge new versions of OSTD into the existing verified code base. We began verification at version 15, and later merged version 16.2, only one major version number behind the main development.

In the end, our goal is simple: to make kernel soundness a concrete, checkable property rather than an assumption. With precise models, machine-checked invariants, and growing proof automation, soundness can move from an informal claim to something we can state, verify, and maintain. As the project evolves, we hope this approach will make it possible to build and develop Asterinas with a level of confidence that was previously out of reach.
