#  Wake struct and related functions
  #  Wake
  #  show
  #  move_wake!
  #  body_to_wake!
  #  vortex_to_target
  #  release_vortex!
  #  set_edge_strength!
  #  cancel_buffer_Γ!

mutable struct Wake{T}
    xy::Matrix{T}
    Γ::Vector{T}
    uv::Matrix{T}
end

function Base.show(io::IO, w::Wake)
    print(io, "Wake x,y = ($(w.xy[1,:])\n")
    print(io, "            $(w.xy[2,:]))\n")
    print(io, "     Γ   = ($(w.Γ))")
end

""" initialization functions """
Wake() = Wake([0, 0], 0.0, [0, 0])

#initial with the buffer panel to be cancelled
function Wake(foil::Foil{T}) where T<:Real
    Wake{T}(reshape(foil.edge[:, end], (2, 1)), [-foil.μ_edge[end]], [0.0 0.0]')
end

function Wake(foils::Vector{Foil{T}}) where {T<:Real}
    N = length(foils)
    xy = zeros(2,N)
    Γs = zeros(N)
    uv = zeros(2,N)
    for (i,foil) in enumerate(foils)
        xy[:,i] = foil.edge[:,end]
    end
    Wake{T}(xy, Γs, uv)
end

function move_wake!(wake::Wake, flow::FlowParams)
    wake.xy += wake.uv .* flow.Δt
    nothing
end

function wake_self_vel!(wake::Wake, flow::FlowParams)
    wake.uv .+= vortex_to_target(wake.xy, wake.xy, wake.Γ, flow)
    nothing
end

"""
    body_to_wake!(wake :: Wake, foil :: Foil)

Influence of body onto the wake and the edge onto the wake
"""
function body_to_wake!(wake::Wake, foil::Foil,flow::FlowParams)
    x1, x2, y = panel_frame(wake.xy, foil.foil)
    nw, nb = size(x1)
    lexp = zeros((nw, nb))
    texp = zeros((nw, nb))
    yc = zeros((nw, nb))
    xc = zeros((nw, nb))
    β = atan.(-foil.normals[1, :], foil.normals[2, :])
    β = repeat(β, 1, nw)'
    @. lexp = log((x1^2 + y^2) / (x2^2 + y^2)) / (4π)
    @. texp = (atan(y, x2) - atan(y, x1)) / (2π)
    @. xc = lexp * cos(β) - texp * sin(β)
    @. yc = lexp * sin(β) + texp * cos(β)
    wake.uv .+= [xc * foil.σs yc * foil.σs]'
    #cirulatory effects    
    fg, eg = get_circulations(foil)
    Γs = [fg... eg...]
    ps = [foil.foil foil.edge]
    wake.uv .+= vortex_to_target(ps, wake.xy, Γs, flow)
    nothing
end

function vortex_to_target(sources, targets, Γs, flow)
    ns = size(sources)[2]
    nt = size(targets)[2]
    vels = zeros((2, nt))
    vel = zeros(nt)
    for i = 1:ns
        dx = targets[1, :] .- sources[1, i]
        dy = targets[2, :] .- sources[2, i]
        @. vel = Γs[i] / (2π * sqrt((dx^2 + dy^2)^2 + flow.δ^4))
        @. vels[1, :] += dy * vel
        @. vels[2, :] -= dx * vel
    end
    vels
end

function release_vortex!(wake::Wake, foil::Foil)
    # wake.xy = [wake.xy foil.edge[:, end]]
    wake.xy = [wake.xy foil.edge[:, 2]]
    wake.Γ = [wake.Γ..., (foil.μ_edge[1] - foil.μ_edge[2])]
    # Set all back to zero for the next time step
    wake.uv = [wake.uv .* 0.0 [0.0, 0.0]]

    if any(foil.μ_ledge .!= 0)
        wake.xy = [wake.xy foil.ledge[:,2]]
        wake.Γ = [wake.Γ..., (foil.μ_ledge[1] - foil.μ_ledge[2])]
        wake.uv = [wake.uv .* 0.0 [0.0, 0.0]]
    end
    nothing
end
function cancel_buffer_Γ!(wake::Wake, foil::Foil)
    #TODO : Add iterator for matching 1->i for nth foil
    wake.xy[:, 1] = foil.edge[:, end]
    wake.Γ[1] = -foil.μ_edge[end]
    #LESP
    if foil.μ_ledge[2] != 0
        wake.xy[:, 2] = foil.ledge[:, end]
        wake.Γ[2] = -foil.μ_ledge[end]
    end
    nothing
end
function cancel_buffer_Γ!(wake::Wake{T}, foils::Vector{Foil{T}}) where T<:Real
    for i in CartesianIndices(foils)
        wake.xy[:, i] = foils[i].edge[:, end]
        wake.Γ[i] = -foils[i].μ_edge[end]
        #LESP --> TODO: fix for multiple swimmers
        if foils[i].μ_ledge[2] != 0
            wake.xy[:, 2] = foil.ledge[:, end]
            wake.Γ[2] = -foil.μ_ledge[end]
        end
    end
    nothing
end