using DataStructures
export EGraph, add_enode!, rebuild!, saturate!

# make an eclass_id be a SymbolicUtils node
# TODO: make this a type pls
id_term(id, T=Real) = term(id_term, id, type=T)
is_eid(t) = istree(t) && operation(t) === id_term

# ids are just UInt64
const Id = UInt64

# UNDER CONSTRUCTION
struct EID{T} <: Symbolic{T}
    istree::Bool
    id::Id
end

function gen_id(graph)
    eid = rand(Id)

    while haskey(graph.eclasses, eid)
        eid = gen_id()
    end
    return eid
end

struct EGraph
    union::Dict{Id, MutableBinaryMinHeap{Id}} # Equivalent eclass Ids
    eclasses::Dict{Id, Set} # Id -> eclasses;
                # Here many Ids can map to the same Set, but `union` should give the canonical id
    hashcons::Dict{Any, Id} # e-node -> Eclass Id
end

EGraph() = EGraph(Dict(), Dict(), Dict())

# modifies the `graph` to add an expr to
# to the egraph as an e-node, creating the required eclasses
# returns the eclass id and enode
# XXX: Just write the fully unrolled version here
# XXX: Returns: eid, and boolean flag denoting if the node is actually new
function add_enode!(graph, expr, iscanonical=false)
    is_eid(expr) && return (first(arguments(expr)), false)
    haskey(graph.hashcons, expr) && return (graph.hashcons[expr], false)

    if !iscanonical && istree(expr)
        args = map(a->id_term(first(add_enode!(graph, a))), arguments(expr))
        expr = term(operation(expr), args..., type=symtype(expr))
        add_enode!(graph, expr, true)
    end

    # new id
    eid = gen_id(graph)
    graph.hashcons[expr] = eid
    graph.union[eid] = MutableBinaryMinHeap([eid])
    graph.eclasses[eid] = Set([expr])
    return (eid, true)
end

function merge_eids!(graph, eid1, eid2)
    has1 = haskey(graph.union, eid1)
    has2 = haskey(graph.union, eid2)

    # they are the same
    if has1 && has2 && graph.union[eid1] === graph.union[eid2]
        return first(graph.union[eid1])
    end

    if !has1 && !has2
        graph.union[eid1] = graph.union[eid2] = MutableBinaryMinHeap([eid1, eid2])
    elseif has1 && has2
        while has2 && !isempty(graph.union[eid2])
            push!(graph.union[eid1], pop!(graph.union[eid2]))
        end
        graph.union[eid2] = graph.union[eid1]
    elseif has1
        set = graph.union[eid2] = graph.union[eid1]
        push!(set, eid2)
    elseif has2
        set = graph.union[eid1] = graph.union[eid2]
        push!(set, eid1)
    end
    first(graph.union[eid1])
end

# match a single node with rule, assume we are not looking at equivalent
# nodes at this point. Just one path of the graph
function saturate!(graph, rules; nodes=graph.hashcons)
    # XXX: use rule.depth for recursively evaluating

    saturated = false
    while !saturated
        matches = []
        saturated = true
        for (node, eid) in nodes
            for rule in rules
                node′ = rule(node)
                if node′ !== nothing && !isequal(node, node′)
                    push!(matches, (eid, node′))
                end
            end
        end
        for (eid, node′) in matches
            eid′, isnew = add_enode!(graph, node′)
            if isnew
                saturated = false
            end
            merge_eids!(graph, eid, eid′)
        end
        rebuild!(graph)
    end
    graph
end

function rebuild!(graph)
    println("OK")
end

#=
# This function must be called only after `node` is canonicalized!
# returns the id of the eclass with the node, if a node is not in the graph, will add it.
function touch(graph, node)
    if !canonical
        node = canonicalize(node)
    end
    haskey(graph.hashcons, node) ? graph.hashcons[node] : add!(graph, node)
end

# add a node to egraph
function add!(graph, node)
    # XXX: Should this be canonical?
    if istree(node)
        ids = map(a->add!(graph, node), arguments(node))
        node = term(operation(node), map(eclass_id, ids), type=symtype(node))
end

function equality_saturation(expr, rewrites)
    graph = init_egraph(expr)
    for 1=1:100

        matches = []
        for rw in rewrites
            for (c, t) in iterate_exprs(graph)
                rw.matcher((t,), EMPTY_IMMUTABLE_DICT) do bindings, n
                    if n == 1
                        push!(matches, (rw, bindings, c))
                    end
                end
            end
        end

        for (rw, bindings, c)
            c′ = add(graph, rw.rhs(bindings))
            merge!(graph, c, c′)
        end

        rebuild(graph)
end
function canonical_id(graph, id) # find
    first(graph.union[id])
end

function add(graph, expr) # return Id
    if haskey(graph.hashcons, expr)
        return graph.hashcons[expr]
    else
        id = new_class(graph, expr)
        graph.hascons[expr] = id
    end
end


function merge!(graph, id1, id2)
    cid1 = canonical_id(graph, id1)
    if cid1 == canonical_id(graph, id2)
        cid1
    else
        newset = union!(get!(()->MutableBinaryMinHeap{Id}(), graph.union, id1), 
                       get!(()->MutableBinaryMinHeap{Id}(), graph.union, id2))
        graph.union[id1] = graph.union[id2] = newset
    end
    canonical_id(graph, id1)
end

find(G, a) = first(G.union[a])

function add_recursive(G, expr)
    if istree(expr)
        args = map(x->add_recursive(G,x), unsorted_arguments(expr))
        add(G, Term{symtype(expr)}(operation(expr), args))
    else
        add(G, expr)
    end
end

function canonicalize(graph, term)
    find
    (graph.union, term)
end

function iterate_exprs(graph)
end

function extend_graph(graph, rule)
    rhs = rule.rhs

    try
        # n == 1 means that exactly one term of the input (term,) was matched
        function success(bindings, n)
            if n != 1
                return nothing
            end

            canonical_bindings = EMPTY_IMMUTABLE_DICT
            for (k, val) in bindings
                canonical_bindings = assoc(k, canonicalize(graph, val))
            end
            merge(c, rhs(canonical_bindings))
        end
        c = 
        return rule.matcher(success, (term,), EMPTY_IMMUTABLE_DICT)
    catch err
        throw(RuleRewriteError(rule, term))
    end
end



##### Equality saturation
#

=#