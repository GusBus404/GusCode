abstract type Body end

#  Foil struct and related functions
mutable struct Foil{T} <: Body
    kine  #kinematics: heave or traveling wave function
    f::T #wave freq
    k::T # wave number
    N::Int # number of elements
    _foil::Matrix{T} # coordinates in the Body Frame
    foil::Matrix{T}  # Absolute fram
    col::Matrix{T}  # collocation points
    σs::Vector{T} #source strengths on the body 
    μs::Vector{T} #doublet strengths on the body
    edge::Matrix{T}
    μ_edge::Vector{T}
    chord::T
    normals::Matrix{T}
    tangents::Matrix{T}
    panel_lengths::Vector{T}
    panel_vel::Matrix{T}
    wake_ind_vel::Matrix{T} #velocity induced by wake at collocation points
    ledge::Matrix{T} #leading edge panel 
    μ_ledge::Vector{T} #leading edge doublet strength
    pivot::T # where the foil pivots about as a fraction of chord
end

# NACA0012 Foil
function make_naca(N; chord=1, thick=0.12)
    # N = 7
    an = [0.2969, -0.126, -0.3516, 0.2843, -0.1036]
    # T = 0.12 #thickness
    yt(x_) = thick / 0.2 * (an[1] * x_^0.5 + an[2] * x_ + an[3] * x_^2 + an[4] * x_^3 + an[5] * x_^4)
    #neutral x
    x = (1 .- cos.(LinRange(0, pi, (N + 2) ÷ 2))) / 2.0
    foil = [[x[end:-1:1]; x[2:end]]'
        [-yt.(x[end:-1:1]); yt.(x[2:end])]']
    foil .* chord
end

function make_waveform(a0=0.1, a=[0.367, 0.323, 0.310]; T=Float64)
    a0 = T(a0)
    a = a .|> T
    f = k = T(1)

    amp(x, a) = a[1] + a[2] * x + a[3] * x^2
    h(x, f, k, t) = a0 * amp(x, a) * sin(2π * (k * x - f * t)) .|> T
    # h(x,t) = f,k -> h(x,f,k,t)
    h
end

function make_ang(a0=0.1; a=[0.367, 0.323, 0.310])
    a0 = a0
    a = a
    f = π
    k = 0.5

    amp(x, a) = a[1] + a[2] * x + a[3] * x^2
    h(x, f, k, t) = a0 * amp(x, a) * sin(2π * (k * x - f * t))
    h
end

function make_heave_pitch(h0, θ0; T=Float64)
    θ(f, t, ψ) = θ0 * sin(2 * π * f * t + ψ)
    h(f, t) = h0 * sin(2 * π * f * t)
    [h, θ]
end

function make_eldredge(α, αdot;s = 0.001,chord=1.0, Uinf = 1.0)
    K = αdot*chord/(2*Uinf)
    a(σ) = π^2 *K /(2*α*(1.0 -σ))
    
    t1 = 1.0
    t2 = t1 + α/2/K
    t3 = t2 + π*α/4/K - α/2/K
    t4 = t3 + α/2/K
    eld(t) = log((cosh(a(s)*(t - t1))*cosh(a(s)*(t - t4)))/
                 (cosh(a(s)*(t - t2))*cosh(a(s)*(t - t3))))
    maxG = maximum(filter(x->!isnan(x), eld.(0:0.1:100)))
    pitch(f,tt,p) = α*eld(tt)/maxG
    heave(f,t) = 0.0
    [heave, pitch]
end

function no_motion(; T=Float64)
    sig(x, f, k, t) = 0.0
end

function angle_of_attack(; aoa=5, T=Float64)
    sig(x, f, k, t) = rotation(-aoa * pi / 180)'
end

function norms(foil)
    dxdy = diff(foil, dims=2)
    lengths = sqrt.(sum(abs2, diff(foil, dims=2), dims=1))
    tx = dxdy[1, :]' ./ lengths
    ty = dxdy[2, :]' ./ lengths
    # tangents x,y normals x, y  lengths
    return [tx; ty], [-ty; tx], lengths
end

function norms!(foil::Foil)
    dxdy = diff(foil.foil, dims=2)
    lengths = sqrt.(sum(abs2, dxdy, dims=1))
    tx = dxdy[1, :]' ./ lengths
    ty = dxdy[2, :]' ./ lengths
    # tangents x,y normals x, y  lengths
    foil.tangents = [tx; ty]
    foil.normals = [-ty; tx]
    foil.panel_lengths = [lengths...]
    nothing
end

get_mdpts(foil) = (foil[:, 2:end] + foil[:, 1:end-1]) ./ 2

function move_edge!(foil::Foil, flow::FlowParams)
    edge_vec = [(foil.tangents[1, end] - foil.tangents[1, 1]), (foil.tangents[2, end] - foil.tangents[2, 1])]
    edge_vec ./= norm(edge_vec)
    edge_vec .*= flow.Uinf * flow.Δt 
    #The edge starts at the TE -> advects some scale down -> the last midpoint
    foil.edge = [foil.foil[:, end] (foil.foil[:, end] .+ 0.5 * edge_vec) foil.edge[:, 2]]
    #static buffer is a bugger
    # foil.edge = [foil.foil[:, end] (foil.foil[:, end] .+ 0.4 * edge_vec) (foil.foil[:, end] .+ 1.4 * edge_vec)]
    nothing
end

function set_collocation!(foil::Foil, S=0.009)
    foil.col = (get_mdpts(foil.foil) .+ repeat(S .* foil.panel_lengths', 2, 1) .* -foil.normals)
end

rotation(α) = [cos(α) -sin(α)
               sin(α) cos(α)]

function next_foil_pos(foil::Foil, flow::FlowParams)
    #perform kinematics
    if typeof(foil.kine) == Vector{Function}
        h = foil.kine[1](foil.f, flow.n * flow.Δt)
        θ = foil.kine[2](foil.f, flow.n * flow.Δt, -π/2)
        pos = rotate_about(foil, θ)
        pos[2, :] .+= h
        #Advance the foil in flow
        pos .+= [-flow.Uinf, 0] .* flow.Δt .* flow.n
    else
        pos = deepcopy(foil.foil)
        pos[2, :] = foil._foil[2, :] .+ foil.kine.(foil._foil[1, :], foil.f, foil.k, flow.n * flow.Δt)
        #Advance the foil in flow
        pos .+= [-flow.Uinf, 0] .* flow.Δt
    end
    pos
end

function move_foil!(foil::Foil, pos)
    foil.foil = pos
    norms!(foil)
    set_collocation!(foil)
    move_edge!(foil, flow)
    flow.n += 1
end

function do_kinematics!(foils::Vector{Foil{T}}, flow::FlowParams) where T<:Real
    for foil in foils
    #perform kinematics
        if typeof(foil.kine) == Vector{Function}
            le = foil.foil[1,foil.N÷2 + 1]
            h = foil.kine[1](foil.f, flow.n * flow.Δt)
            θ = foil.kine[2](foil.f, flow.n * flow.Δt, -π/2)
            rotate_about!(foil, θ)
            foil.foil[2, :] .+= h
            #Advance the foil in flow
            foil.foil[1,:] .+= le
            foil.foil .+= [-flow.Uinf, 0] .* flow.Δt 
            
        else
            foil.foil[2, :] = foil._foil[2, :] .+ foil.kine.(foil._foil[1, :], foil.f, foil.k, flow.n * flow.Δt)
            #Advance the foil in flow
            foil.foil .+= [-flow.Uinf, 0] .* flow.Δt
        end
        norms!(foil)
        set_collocation!(foil)
        move_edge!(foil, flow)
    end
    flow.n += 1
    nothing
end

function rotate_about!(foil, θ)

    foil.foil = ([foil._foil[1, :] .- foil.pivot foil._foil[2, :]] * rotation(θ))'
    foil.foil[1, :] .+= foil.pivot 
    nothing
end
function rotate_about(foil, θ)
    pos = ([foil._foil[1, :] .- foil.pivot foil._foil[2, :]] * rotation(θ))'
    pos[1, :] .+= foil.pivot 
    pos
end
function set_edge_strength!(foil::Foil)
    """Assumes that foil.μs has been set for the current time step 
        TODO: Extend to perform streamline based Kutta condition
    """
    foil.μ_edge[2] = foil.μ_edge[1]
    foil.μ_edge[1] = foil.μs[end] - foil.μs[1]
    nothing
end
function set_ledge_strength!(foil::Foil)
    """Assumes that foil.μs has been set for the current time step 
        TODO: Extend to perform streamline based Kutta condition
    """
    mid = foil.N ÷ 2
    foil.μ_ledge[2] = foil.μ_ledge[1]
    foil.μ_ledge[1] = foil.μs[mid] - foil.μs[mid+1]
    nothing
end