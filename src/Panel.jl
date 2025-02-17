#  Panel# related functions

function source_inf(x1, x2, z)
    (x1 * log(x1^2 + z^2) - x2 * log(x2^2 + z^2) - 2 * (x1 - x2) +
     2 * z * (mod2pi(atan(z, x2)) - mod2pi(atan(z, x1)))) / (4π)
end

doublet_inf(x1, x2, z) = -(mod2pi(atan(z, x2)) - mod2pi(atan(z, x1))) / (2π)

get_mdpts(foil) = (foil[:, 2:end] + foil[:, 1:(end - 1)]) ./ 2

"""
    get_panel_vels(foil::Foil,fp::FlowParams)

Autodiff the panel Velocities
accepts 1d waveforms and 2D prescribed kinematics
"""
function get_panel_vels(foil::Foil, fp::FlowParams)
    _t = fp.n * fp.Δt
    col = get_mdpts(foil._foil)

    if typeof(foil.kine) == Vector{Function}
        theta(t) = foil.kine[2](foil.f, t, foil.ψ)
        heave(t) = foil.kine[1](foil.f, t)
        dx(t) = col[1, :] * cos(theta(t)) - col[2, :] * sin(theta(t))
        dy(t) = col[1, :] * sin(theta(t)) + col[2, :] * cos(theta(t)) .+ heave(t)
        vels = [
            ForwardDiff.derivative(t -> dx(t), _t),
            ForwardDiff.derivative(t -> dy(t), _t),
        ]
    else
        vy = ForwardDiff.derivative(t -> foil.kine.(col[1, :], foil.f, foil.k, t, foil.ψ), _t)
        vels = [zeros(size(vy)) vy]
    end
    vels
end

function get_panel_vels!(foil::Foil, fp::FlowParams)
    _t = fp.n * fp.Δt
    col = get_mdpts(foil._foil)
    #TODO switch to a s-exp label dispatch
    if typeof(foil.kine) == Vector{Function}
        theta(t) = foil.kine[2](foil.f, t, foil.ψ)
        heave(t) = foil.kine[1](foil.f, t)
        dx(t) = col[1, :] * cos(theta(t)) - col[2, :] * sin(theta(t))
        dy(t) = col[1, :] * sin(theta(t)) + col[2, :] * cos(theta(t)) .+ heave(t)

        foil.panel_vel[1, :] = ForwardDiff.derivative(t -> dx(t), _t)
        foil.panel_vel[2, :] = ForwardDiff.derivative(t -> dy(t), _t)
    else
        vy = ForwardDiff.derivative(t -> foil.kine.(col[1, :], foil.f, foil.k, t, foil.ψ), _t)
        foil.panel_vel = [zeros(size(vy)) vy]'
    end
    nothing
end

""" flow.n += 1
    panel_frame(target,source)

TBW
"""
function panel_frame(target, source)
    _, Ns = size(source)
    _, Nt = size(target)
    Ns -= 1 #TE accomodations
    x1 = zeros(Ns, Nt)
    x2 = zeros(Ns, Nt)
    y = zeros(Ns, Nt)
    ts, _, _ = norms(source)
    txMat = repeat(ts[1, :]', Nt, 1)
    tyMat = repeat(ts[2, :]', Nt, 1)
    dx = repeat(target[1, :], 1, Ns) - repeat(source[1, 1:(end - 1)]', Nt, 1)
    dy = repeat(target[2, :], 1, Ns) - repeat(source[2, 1:(end - 1)]', Nt, 1)
    x1 = dx .* txMat + dy .* tyMat
    y = -dx .* tyMat + dy .* txMat
    x2 = x1 - repeat(sum(diff(source, dims = 2) .* ts, dims = 1), Nt, 1)
    x1, x2, y
end

function edge_circulation(foil::Foil)
    -foil.μ_edge[1], foil.μ_edge[1] - foil.μ_edge[2], foil.μ_edge[2]
end
"""
    get_circulations(foil::Foil)

return the circulation bound to the foil and the edge panels
"""
function get_circulations(foil::Foil)
    egamma = edge_circulation(foil)
    fgamma = [-foil.μs[1], -diff(foil.μs)..., foil.μs[end]]
    fgamma, egamma
end

function make_infs(foil::Foil; ϵ = 1e-10)
    x1, x2, y = panel_frame(foil.col, foil.foil)
    ymask = abs.(y) .> ϵ
    y = y .* ymask
    doubletMat = doublet_inf.(x1, x2, y)
    # doubletMat[getindex.(doubletMat .== diag(doubletMat))] .= 0.5
    sourceMat = source_inf.(x1, x2, y)
    x1, x2, y = panel_frame(foil.col, foil.edge)
    edgeInf = doublet_inf.(x1, x2, y)
    edgeMat = zeros(size(doubletMat))
    edgeMat[:, 1] = -edgeInf[:, 1]
    edgeMat[:, end] = edgeInf[:, 1]
    A = doubletMat + edgeMat
    doubletMat + edgeMat, sourceMat, edgeInf[:, 2]
end

function make_infs(foils::Vector{Foil{T}}; ϵ = 1e-10) where {T <: Real}
    nfoils = length(foils)
    Ns = [foil.N for foil in foils]    
    N = sum(Ns)
    Ns = [0 cumsum(Ns)...]

    allcols = hcat([f.col for f in foils]...)

    doubletMat = zeros(N, N)
    sourceMat = zeros(N, N)
    edgeMat = zeros(N, N)

    buffers = zeros(nfoils, N)
    

    for j = 1:nfoils
        x1, x2, y = panel_frame(allcols, foils[j].foil)
        ymask = abs.(y) .> ϵ
        y = y .* ymask
        doubletMat[:, (Ns[j] + 1):Ns[j + 1]] = doublet_inf.(x1, x2,y)
        sourceMat[:, (Ns[j] + 1):Ns[j + 1]]  = source_inf.(x1, x2, y)
        
        x1, x2, y = panel_frame(allcols, foils[j].edge)
        edgeInf = doublet_inf.(x1, x2, y)
        buffers[j, :] = edgeInf[:, 2]    
        edgeMat[:, Ns[j] + 1] = -edgeInf[:, 1]
        edgeMat[:, Ns[j + 1]] = edgeInf[:, 1]    
    end
    A = doubletMat + edgeMat
    doubletMat + edgeMat, sourceMat, buffers'
end

function set_edge_strength!(foil::Foil)
    """Assumes that foil.μs has been set for the current time step 
        TODO: Extend to perform streamline based Kutta condition
    """
    foil.μ_edge[2] = foil.μ_edge[1]
    
    foil.μ_edge[1] = foil.μs[end] - foil.μs[1]
    nothing
end
function set_ledge_strength!(foil::Foil; lesp = true)
    """Assumes that foil.μs has been set for the current time step 
        lesp is if the leading edge is a stagnation point is active
    """
    mid = foil.N ÷ 2
    foil.μ_ledge[2] = foil.μ_ledge[1]
    foil.μ_ledge[1] = lesp ? foil.μs[mid] - foil.μs[mid + 1] : 0.0
    nothing
end

""" 
    setσ!(foil::Foil, wake::Wake,flow::FlowParams)
Outward normal velocity to enforce no penetration condition
due to 
velocity from free stream
velocity from motion 
Tack on the wake influence outside of this function
"""
function setσ!(foil::Foil, flow::FlowParams; U_b = nothing)
    U_b = isnothing(U_b) ? -flow.Uinf : U_b
    get_panel_vels!(foil, flow)
    foil.σs = (U_b .+ foil.panel_vel[1, :]) .* foil.normals[1, :] +
              (foil.panel_vel[2, :]) .* foil.normals[2, :]
    nothing
end

function turn_σ!(foil::Foil, flow::FlowParams, turn)
    #TODO: add for other kinematics
    ff = get_mdpts(([foil._foil[1, :] .- foil.pivot foil._foil[2, :] .+
                                                    foil.kine.(foil._foil[1, :],
        foil.f,
        foil.k,
        flow.n * flow.Δt, foil.ψ)] * rotation(-turn))') .+ foil.LE
    vel = (foil.col - ff) ./ flow.Δt
    foil.σs += vel[1, :] .* foil.normals[1, :] + vel[2, :] .* foil.normals[2, :]
    nothing
end

function panel_pressure(foil::Foil, flow, old_mus, old_phis, phi; U_b = nothing)
    U_b = isnothing(U_b) ? -flow.Uinf : U_b

    dmudt = get_dt([foil.μs'; old_mus[1:2, :]], flow)
    dphidt = get_dt([phi'; old_phis[1:2, :]], flow)

    qt = get_qt(foil)
    qt .+= repeat(foil.σs', 2, 1) .* foil.normals
    # qt .-= foil.wake_ind_vel 

    p_s = sum((qt + foil.wake_ind_vel) .^ 2, dims = 1) / 2.0
    p_us = dmudt' + dphidt' -
           sum(([U_b; 0] .+ foil.panel_vel) .* (qt), dims = 1)
    # Calculate the total pressure coefficient
    """
    ∫∞→Px1 d(∇×Ψ)/dt dC + dΦ/dt|body - (VG + VGp + (Ωxr))⋅∇(Φ + ϕ) + 1/2||∇Φ +(∇×Ψ)|^2  = Pinf - Px1 /ρ
    """
    p = p_s + p_us
    p
end

function edge_to_body(foil::Foil, flow::FlowParams)
    Γs = [-foil.μ_edge[1] foil.μ_edge[1]]
    ps = foil.edge[:, 1:2]
    vortex_to_target(ps, foil.col, Γs, flow)
end
