function est = run_filter(model,meas)

% This is the MATLAB code for the Generalized Labeled Multi-Bernoulli filter proposed in
% B.-T. Vo, and B.-N. Vo, "Labeled Random Finite Sets and Multi-Object Conjugate Priors," IEEE Trans. Signal Processing, Vol. 61, No. 13, pp. 3460-3475, 2013.
% http://ba-ngu.vo-au.com/vo/VV_Conjugate_TSP13.pdf
% with corresponding implementation details given in
% B.-N. Vo, B.-T. Vo, and D. Phung, "Labeled Random Finite Sets and the Bayes Multi-Target Tracking Filter," IEEE Trans. Signal Processing, Vol. 62, No. 24, pp. 6554-6567, 2014
% http://ba-ngu.vo-au.com/vo/VVP_GLMB_TSP14.pdf
%
% Note 1: no lookahead PHD/CPHD allocation is implemented in this code, a simple proportional weighting scheme is used for readability
% Note 2: the simple example used here is the same as in the CB-MeMBer filter code for a quick demonstration and comparison purposes
% Note 3: more difficult scenarios require more components/hypotheses (thus exec time) and/or a better lookahead
% ---BibTeX entry
% @ARTICLE{GLMB1,
% author={B.-T. Vo and B.-N. Vo
% journal={IEEE Transactions on Signal Processing},
% title={Labeled Random Finite Sets and Multi-Object Conjugate Priors},
% year={2013},
% month={Jul}
% volume={61},
% number={13},
% pages={3460-3475}}
%
% @ARTICLE{GLMB2,
% author={B.-T. Vo and B.-N. Vo and D. Phung},
% journal={IEEE Transactions on Signal Processing},
% title={Labeled Random Finite Sets and the Bayes Multi-Target Tracking Filter},
% year={2014},
% month={Dec}
% volume={62},
% number={24},
% pages={6554-6567}}
%---

%=== Setup

%output variables
est.X= cell(meas.K,1);
est.N= zeros(meas.K,1);
est.L= cell(meas.K,1);
est.T= {};
est.M= 0;
est.J= []; est.H= {};

%filter parameters
filter.H_bth= 5;                    %requested number of birth components/hypotheses
filter.H_sur= 3000;                 %requested number of surviving components/hypotheses
filter.H_upd= 3000;                 %requested number of updated components/hypotheses
filter.H_max= 3000;                 %cap on number of posterior components/hypotheses
filter.hyp_threshold= 1e-15;        %pruning threshold for components/hypotheses

filter.L_max= 100;                  %limit on number of Gaussians in each track - not implemented yet
filter.elim_threshold= 1e-5;        %pruning threshold for Gaussians in each track - not implemented yet
filter.merge_threshold= 4;          %merging threshold for Gaussians in each track - not implemented yet

filter.P_G= 0.9999999;                           %gate size in percentage
filter.gamma= chi2inv(filter.P_G,model.z_dim);   %inv chi^2 dn gamma value
filter.gate_flag= 1;                             %gating on or off 1/0

filter.run_flag= 'disp';            %'disp' or 'silence' for on the fly output

est.filter= filter;

%=== Filtering

%initial prior
glmb_update.tt= cell(0,1);      %track table for GLMB (cell array of structs for individual tracks)
glmb_update.w= 1;               %vector of GLMB component/hypothesis weights
glmb_update.I= {[]};            %cell of GLMB component/hypothesis labels (labels are indices/entries in track table)
glmb_update.n= 0;               %vector of GLMB component/hypothesis cardinalities
glmb_update.cdn= 1;             %cardinality distribution of GLMB (vector of cardinality distribution probabilities)

%recursive filtering
for k=1:meas.K
    
    %prediction and update
    glmb_predict= predict(glmb_update,model,filter,k);          H_predict= length(glmb_predict.w);
    glmb_update= update(glmb_predict,model,filter,meas,k);      H_posterior= length(glmb_update.w);
    
    %pruning and truncation
    glmb_update= prune(glmb_update,filter);                     H_prune= length(glmb_update.w);
    glmb_update= cap(glmb_update,filter);                       H_cap= length(glmb_update.w);
    
    %state estimation and display diagnostics
    est= extract_estimates_recursive(glmb_update,model,meas,est); %[est.X{k},est.N(k),est.L{k}]= extract_estimates(glmb_update,model);
    
    % 新增: 提取GM-PHD
    est.gm_phd{k} = extract_gmphd(glmb_update, model);

    display_diaginfo(glmb_update,k,est,filter,H_predict,H_posterior,H_prune,H_cap);
    
end
end

function glmb_predict= predict(glmb_update,model,filter,k)
%---generate birth hypotheses/components
%create birth tracks
tt_birth= cell(length(model.r_birth),1);                                            %initialize cell array
for tabbidx=1:length(model.r_birth)
    tt_birth{tabbidx}.m= model.m_birth{tabbidx};                                   %means of Gaussians for birth track
    tt_birth{tabbidx}.P= model.P_birth{tabbidx};                                   %covs of Gaussians for birth track
    tt_birth{tabbidx}.w= model.w_birth{tabbidx}(:);                                %weights of Gaussians for birth track
    tt_birth{tabbidx}.l= [k;tabbidx];                                              %track label
    tt_birth{tabbidx}.ah= [];                                                      %track association history (empty at birth)
end
glmb_birth.tt= tt_birth;                                                            %copy track table back to GLMB struct

%calculate best birth hypotheses/components
costv= model.r_birth./(1-model.r_birth);                                            %cost vector
neglogcostv= -log(costv);                                                           %negative log cost
[bpaths,nlcost]= kshortestwrap_pred(neglogcostv,filter.H_bth);                      %k-shortest path to calculate k-best births hypotheses/components

%generate corrresponding birth hypotheses/components
for hidx=1:length(nlcost)
    birth_hypcmp_tmp= bpaths{hidx}(:);  
    glmb_birth.w(hidx)= sum(log(1-model.r_birth))-nlcost(hidx);                     %hypothesis/component weight
    glmb_birth.I{hidx}= birth_hypcmp_tmp;                                           %hypothesis/component tracks (via indices to track table)
    glmb_birth.n(hidx)= length(birth_hypcmp_tmp);                                   %hypothesis/component cardinality
end
glmb_birth.w= exp(glmb_birth.w-logsumexp(glmb_birth.w));                            %normalize weights

%extract cardinality distribution
for card=0:max(glmb_birth.n)
    glmb_birth.cdn(card+1)= sum(glmb_birth.w(glmb_birth.n==card));                  %extract probability of n targets
end

%---generate survival hypotheses/components
%create surviving tracks - via time prediction (single target CK)
tt_survive= cell(length(glmb_update.tt),1);                                                                                 %initialize cell array
for tabsidx=1:length(glmb_update.tt)
    [mtemp_predict,Ptemp_predict]= kalman_predict_multiple(model,glmb_update.tt{tabsidx}.m,glmb_update.tt{tabsidx}.P);      %kalman prediction for GM
    tt_survive{tabsidx}.m= mtemp_predict;                                                                                   %means of Gaussians for surviving track
    tt_survive{tabsidx}.P= Ptemp_predict;                                                                                   %covs of Gaussians for surviving track
    tt_survive{tabsidx}.w= glmb_update.tt{tabsidx}.w;                                                                       %weights of Gaussians for surviving track
    tt_survive{tabsidx}.l= glmb_update.tt{tabsidx}.l;                                                                       %track label
    tt_survive{tabsidx}.ah= glmb_update.tt{tabsidx}.ah;                                                                     %track association history (no change at prediction)
end
glmb_survive.tt= tt_survive;                                                                                                %copy track table back to GLMB struct
    
%loop over posterior components/hypotheses
runidx= 1;                                                                                      %counter and index variable for new hypotheses/components
for pidx=1:length(glmb_update.w) 
    if glmb_update.n(pidx)==0 %no target means no deaths
        glmb_survive.w(runidx)= log(glmb_update.w(pidx));       %hypothesis/component weight
        glmb_survive.I{runidx}= glmb_update.I{pidx};            %hypothesis/component tracks (via indices to track table)
        glmb_survive.n(runidx)= glmb_update.n(pidx);            %hypothesis component cardinality
        runidx= runidx+1;
    else %perform prediction for survivals
        %calculate best surviving hypotheses/components
        costv= model.P_S/model.Q_S*ones(glmb_update.n(pidx),1);                                                                     %cost vector
        neglogcostv= -log(costv);                                                                                                   %negative log cost
        [spaths,nlcost]= kshortestwrap_pred(neglogcostv,round(filter.H_sur*sqrt(glmb_update.w(pidx))/sum(sqrt(glmb_update.w))));    %k-shortest path to calculate k-best surviving hypotheses/components
        
        %generate corrresponding surviving hypotheses/components
        for hidx=1:length(nlcost)
            survive_hypcmp_tmp= spaths{hidx}(:);
            glmb_survive.w(runidx)= glmb_update.n(pidx)*log(model.Q_S)+log(glmb_update.w(pidx))-nlcost(hidx);                       %hypothesis/component weight
            glmb_survive.I{runidx}= glmb_update.I{pidx}(survive_hypcmp_tmp);                                                        %hypothesis/component tracks (via indices to track table)
            glmb_survive.n(runidx)= length(survive_hypcmp_tmp);                                                                     %hypothesis/component cardinality
            runidx= runidx+1;
        end
    end
end
glmb_survive.w= exp(glmb_survive.w-logsumexp(glmb_survive.w));                                                                      %normalize weights

%extract cardinality distribution
for card=0:max(glmb_survive.n)
    glmb_survive.cdn(card+1)= sum(glmb_survive.w(glmb_survive.n==card));                                                            %extract probability of n targets
end

%---generate predicted hypotheses/components (by convolution of birth and survive GLMBs)
%perform convolution - just multiplication
glmb_predict.tt= cat(1,glmb_birth.tt,glmb_survive.tt);                                                                              %concatenate track table
for bidx= 1:length(glmb_birth.w)
    for sidx= 1:length(glmb_survive.w)
        hidx= (bidx-1)*length(glmb_survive.w)+sidx;
        glmb_predict.w(hidx)= glmb_birth.w(bidx)*glmb_survive.w(sidx);                                                              %hypothesis/component weight
        glmb_predict.I{hidx}= [glmb_birth.I{bidx}; length(glmb_birth.tt)+glmb_survive.I{sidx}];                                     %hypothesis/component tracks (via indices to track table)
        glmb_predict.n(hidx)= glmb_birth.n(bidx)+glmb_survive.n(sidx);                                                              %hypothesis/component cardinality
    end
end
glmb_predict.w= glmb_predict.w/sum(glmb_predict.w);                                                                                 %normalize weights

%extract cardinality distribution
for card=0:max(glmb_predict.n)
    glmb_predict.cdn(card+1)= sum(glmb_predict.w(glmb_predict.n==card));                                                            %extract probability of n targets
end

%remove duplicate entries and clean track table
glmb_predict= clean_predict(glmb_predict);
end

function glmb_update= update(glmb_predict,model,filter,meas,k)
%gating by tracks
if filter.gate_flag
    m_tracks= [];
    P_tracks= [];
    for tabidx=1:length(glmb_predict.tt)
        m_tracks= cat(2,m_tracks,glmb_predict.tt{tabidx}.m);
        P_tracks= cat(3,P_tracks,glmb_predict.tt{tabidx}.P);
    end
    meas.Z{k}= gate_meas_gms(meas.Z{k},filter.gamma,model,m_tracks,P_tracks);
end
%create updated tracks (single target Bayes update)
m= size(meas.Z{k},2);                                   %number of measurements
tt_update= cell((1+m)*length(glmb_predict.tt),1);       %initialize cell array
%missed detection tracks (legacy tracks)
for tabidx= 1:length(glmb_predict.tt)
    tt_update{tabidx}= glmb_predict.tt{tabidx};         %same track table
    tt_update{tabidx}.ah= [tt_update{tabidx}.ah; 0];    %track association history (updated for missed detection)
end

%measurement updated tracks (all pairs)
allcostm= zeros(length(glmb_predict.tt),m);                                                                                             %global cost matrix 
for emm= 1:m
    for tabidx= 1:length(glmb_predict.tt)
        stoidx= length(glmb_predict.tt)*emm + tabidx; %index of predicted track i updated with measurement j is (number_predicted_tracks*j + i)
        [qz_temp,m_temp,P_temp] = kalman_update_multiple(meas.Z{k}(:,emm),model,glmb_predict.tt{tabidx}.m,glmb_predict.tt{tabidx}.P);   %kalman update for this track and this measurement
        w_temp= qz_temp.*glmb_predict.tt{tabidx}.w+eps;                                                                                 %unnormalized updated weights
        tt_update{stoidx}.m= m_temp;                                                                                                    %means of Gaussians for updated track
        tt_update{stoidx}.P= P_temp;                                                                                                    %covs of Gaussians for updated track
        tt_update{stoidx}.w= w_temp/sum(w_temp);                                                                                        %weights of Gaussians for updated track
        tt_update{stoidx}.l = glmb_predict.tt{tabidx}.l;                                                                                %track label
        tt_update{stoidx}.ah= [glmb_predict.tt{tabidx}.ah; emm];                                                                        %track association history (updated with new measurement)
        allcostm(tabidx,emm)= sum(w_temp);                                                                                              %predictive likelihood
    end
end
glmb_update.tt= tt_update;                                                                                                              %copy track table back to GLMB struct

%component updates
if m==0 %no measurements means all missed detections
    glmb_update.w= -model.lambda_c+glmb_predict.n*log(model.Q_D)+log(glmb_predict.w);       %hypothesis/component weight
    glmb_update.I= glmb_predict.I;                                                          %hypothesis/component tracks (via indices to track table)
    glmb_update.n= glmb_predict.n;                                                          %hypothesis/component cardinality
else %loop over predicted components/hypotheses
    runidx= 1;
    for pidx=1:length(glmb_predict.w)
        if glmb_predict.n(pidx)==0 %no target means all clutter
            glmb_update.w(runidx)= -model.lambda_c+m*log(model.lambda_c*model.pdf_c)+log(glmb_predict.w(pidx));                                 %hypothesis/component weight
            glmb_update.I{runidx}= glmb_predict.I{pidx};                                                                                        %hypothesis/component tracks (via indices to track table)
            glmb_update.n(runidx)= glmb_predict.n(pidx);                                                                                        %hypothesis/component cardinality
            runidx= runidx+1;
        else %otherwise perform update for component
            %calculate best updated hypotheses/components
            costm= model.P_D/model.Q_D*allcostm(glmb_predict.I{pidx},:)/(model.lambda_c*model.pdf_c);                                           %cost matrix
            neglogcostm= -log(costm);                                                                                                           %negative log cost
            [uasses,nlcost]= mbestwrap_updt_custom(neglogcostm,round(filter.H_upd*sqrt(glmb_predict.w(pidx))/sum(sqrt(glmb_predict.w))));    	%murty's algo to calculate m-best assignment hypotheses/components
            
            %generate corrresponding surviving hypotheses/components
            for hidx=1:length(nlcost)
                update_hypcmp_tmp= uasses(hidx,:)';
                glmb_update.w(runidx)= -model.lambda_c+m*log(model.lambda_c*model.pdf_c)+glmb_predict.n(pidx)*log(model.Q_D)+log(glmb_predict.w(pidx))-nlcost(hidx);        %hypothesis/component weight     
                glmb_update.I{runidx}= length(glmb_predict.tt).*update_hypcmp_tmp+glmb_predict.I{pidx};                                                                     %hypothesis/component tracks (via indices to track table)
                glmb_update.n(runidx)= glmb_predict.n(pidx);                                                                                                                %hypothesis/component cardinality
                runidx= runidx+1;
            end
        end
    end
end
glmb_update.w= exp(glmb_update.w-logsumexp(glmb_update.w));                                                                                                                 %normalize weights

%extract cardinality distribution
for card=0:max(glmb_update.n)
    glmb_update.cdn(card+1)= sum(glmb_update.w(glmb_update.n==card));                                                                                                       %extract probability of n targets
end

%remove duplicate entries and clean track table
glmb_update= clean_update(glmb_update);
end



function glmb_temp= clean_predict(glmb_raw)
%hash label sets, find unique ones, merge all duplicates
for hidx= 1:length(glmb_raw.w)
    glmb_raw.hash{hidx}= sprintf('%i*',sort(glmb_raw.I{hidx}(:)'));
end

[cu,~,ic]= unique(glmb_raw.hash);

glmb_temp.tt= glmb_raw.tt;
glmb_temp.w= zeros(length(cu),1);
glmb_temp.I= cell(length(cu),1);
glmb_temp.n= zeros(length(cu),1);
for hidx= 1:length(ic)
        glmb_temp.w(ic(hidx))= glmb_temp.w(ic(hidx))+glmb_raw.w(hidx);
        glmb_temp.I{ic(hidx)}= glmb_raw.I{hidx};
        glmb_temp.n(ic(hidx))= glmb_raw.n(hidx);
end
glmb_temp.cdn= glmb_raw.cdn;
end



function glmb_clean= clean_update(glmb_temp)
%flag used tracks
usedindicator= zeros(length(glmb_temp.tt),1);
for hidx= 1:length(glmb_temp.w)
    usedindicator(glmb_temp.I{hidx})= usedindicator(glmb_temp.I{hidx})+1;
end
trackcount= sum(usedindicator>0);

%remove unused tracks and reindex existing hypotheses/components
newindices= zeros(length(glmb_temp.tt),1); newindices(usedindicator>0)= 1:trackcount;
glmb_clean.tt= glmb_temp.tt(usedindicator>0);
glmb_clean.w= glmb_temp.w;
for hidx= 1:length(glmb_temp.w)
    glmb_clean.I{hidx}= newindices(glmb_temp.I{hidx});
end
glmb_clean.n= glmb_temp.n;
glmb_clean.cdn= glmb_temp.cdn;
end



function glmb_out= prune(glmb_in,filter)
%prune components with weights lower than specified threshold
idxkeep= find(glmb_in.w > filter.hyp_threshold);
glmb_out.tt= glmb_in.tt;
glmb_out.w= glmb_in.w(idxkeep);
glmb_out.I= glmb_in.I(idxkeep);
glmb_out.n= glmb_in.n(idxkeep);

glmb_out.w= glmb_out.w/sum(glmb_out.w);
for card=0:max(glmb_out.n)
    glmb_out.cdn(card+1)= sum(glmb_out.w(glmb_out.n==card));
end
end



function glmb_out= cap(glmb_in,filter)
%cap total number of components to specified maximum
if length(glmb_in.w) > filter.H_max
    [~,idxsort]= sort(glmb_in.w,'descend');
    idxkeep=idxsort(1:filter.H_max);
    glmb_out.tt= glmb_in.tt;
    glmb_out.w= glmb_in.w(idxkeep);
    glmb_out.I= glmb_in.I(idxkeep);
    glmb_out.n= glmb_in.n(idxkeep);
    
    glmb_out.w= glmb_out.w/sum(glmb_out.w);
    for card=0:max(glmb_out.n)
        glmb_out.cdn(card+1)= sum(glmb_out.w(glmb_out.n==card));
    end
else
    glmb_out= glmb_in;
end
end



function est=extract_estimates_recursive(glmb,model,meas,est)
%extract estimates via recursive estimator, where  
%trajectories are extracted via association history, and
%track continuity is guaranteed with a non-trivial estimator

%extract MAP cardinality and corresponding highest weighted component
[~,mode] = max(glmb.cdn); 
M = mode-1;
T= cell(M,1);
J= zeros(2,M);

[~,idxcmp]= max(glmb.w.*(glmb.n==M));
for m=1:M
    idxptr= glmb.I{idxcmp}(m);
    T{m,1}= glmb.tt{idxptr}.ah;
    J(:,m)= glmb.tt{idxptr}.l;
end

H= cell(M,1);
for m=1:M
   H{m}= [num2str(J(1,m)),'.',num2str(J(2,m))]; 
end

%compute dead & updated & new tracks
[~,io,is]= intersect(est.H,H);
[~,id,in]= setxor(est.H,H);

est.M= M;
est.T= cat(1,est.T(id),T(is),T(in));
est.J= cat(2,est.J(:,id),J(:,is),J(:,in));
est.H= cat(1,est.H(id),H(is),H(in));

%write out estimates in standard format
est.N= zeros(meas.K,1);
est.X= cell(meas.K,1);
est.L= cell(meas.K,1);
for t=1:length(est.T)
    ks= est.J(1,t);
    bidx= est.J(2,t);
    tah= est.T{t};
    
    w= model.w_birth{bidx};
    m= model.m_birth{bidx};
    P= model.P_birth{bidx};
    for u=1:length(tah)
        [m,P] = kalman_predict_multiple(model,m,P);
        k= ks+u-1;
        emm= tah(u);
        if emm > 0
            [qz,m,P] = kalman_update_multiple(meas.Z{k}(:,emm),model,m,P);
            w= qz.*w+eps;
            w= w/sum(w);
        end

        [~,idxtrk]= max(w);
        est.N(k)= est.N(k)+1;
        est.X{k}= cat(2,est.X{k},m(:,idxtrk));
        est.L{k}= cat(2,est.L{k},est.J(:,t));
    end
end
end



function [X,N,L]=extract_estimates(glmb,model)
%extract estimates via best cardinality, then 
%best component/hypothesis given best cardinality, then
%best means of tracks given best component/hypothesis and cardinality
[~,mode] = max(glmb.cdn);
N = mode-1;
X= zeros(model.x_dim,N);
L= zeros(2,N);

[~,idxcmp]= max(glmb.w.*(glmb.n==N));
for n=1:N
    [~,idxtrk]= max(glmb.tt{glmb.I{idxcmp}(n)}.w);
    X(:,n)= glmb.tt{glmb.I{idxcmp}(n)}.m(:,idxtrk);
    L(:,n)= glmb.tt{glmb.I{idxcmp}(n)}.l;
end
end



function display_diaginfo(glmb,k,est,filter,H_predict,H_posterior,H_prune,H_cap)
if ~strcmp(filter.run_flag,'silence')
    disp([' time= ',num2str(k),...
        ' #eap cdn=' num2str((0:(length(glmb.cdn)-1))*glmb.cdn(:)),...
        ' #var cdn=' num2str((0:(length(glmb.cdn)-1)).^2*glmb.cdn(:)-((0:(length(glmb.cdn)-1))*glmb.cdn(:))^2,4),...
        ' #est card=' num2str(est.N(k),4),...
        ' #comp pred=' num2str(H_predict,4),...
        ' #comp post=' num2str(H_posterior,4),...
        ' #comp updt=',num2str(H_cap),...
        ' #trax updt=',num2str(length(glmb.tt),4)   ]);
end
end


function gm_phd = extract_gmphd(glmb, model)
% 提取当前时刻的GM-PHD
% 输入: glmb - GLMB结构体, model - 系统模型
% 输出: gm_phd - 结构体{ws, ms, Ps} (权重/均值/协方差)

% 初始化输出结构
gm_phd.ws = []; % 高斯分量的全局权重
gm_phd.ms = []; % 均值向量 (列向量)
gm_phd.Ps = {}; % 协方差元胞数组

% 遍历所有假设
for i = 1:length(glmb.w)
    w_i = glmb.w(i); % 当前假设权重
    
    % 遍历假设中的每个轨迹
    for t_idx = glmb.I{i}
        track = glmb.tt{t_idx}; % 获取轨迹结构
        
        % 轨迹存在概率近似 (取最大值避免重复计算)
        r = min(1, w_i * max(track.w)); 
        
        % 遍历轨迹的高斯分量
        for j = 1:length(track.w)
            % 计算全局权重 = 假设权重 × 轨迹权重 × 存在概率
            w_ij = w_i * track.w(j) * r;
            
            % 添加到输出结构
            gm_phd.ws = [gm_phd.ws; w_ij];
            gm_phd.ms = [gm_phd.ms, track.m(:,j)];
            gm_phd.Ps{end+1} = track.P(:,:,j);
        end
    end
end

% 可选: 合并和修剪高斯分量
gm_phd = gaus_merge(gm_phd, model);
end

function gm_phd = gaus_merge(gm_phd, model)
% 合并相似高斯分量
% 输入/输出: gm_phd - 高斯混合结构

ws = gm_phd.ws; ms = gm_phd.ms; Ps = gm_phd.Ps;
new_ws = []; new_ms = []; new_Ps = {};

while ~isempty(ws)
    % 找到最大权重的分量
    [max_w, idx] = max(ws);
    m_ref = ms(:,idx);
    P_ref = Ps{idx};
    
    % 计算马氏距离阈值 (使用卡方分布)
    merge_threshold = chi2inv(0.99, model.x_dim);
    merge_set = [];
    
    % 寻找所有相似分量
    for j = 1:size(ms,2)
        m_test = ms(:,j);
        P_test = Ps{j};
        innov = m_ref - m_test;
        dist = innov' * inv((P_ref + P_test)/2) * innov;
        
        if dist < merge_threshold
            merge_set = [merge_set, j];
        end
    end
    
    % 合并分量
    w_merge = sum(ws(merge_set));
    m_merge = sum(ws(merge_set).*ms(:,merge_set), 2) / w_merge;
    
    % 协方差合并
    P_merge = zeros(size(P_ref));
    for j = merge_set
        innov = m_merge - ms(:,j);
        P_merge = P_merge + ws(j)*(Ps{j} + innov*innov');
    end
    P_merge = P_merge / w_merge;
    
    % 添加到新列表
    new_ws = [new_ws; w_merge];
    new_ms = [new_ms, m_merge];
    new_Ps{end+1} = P_merge;
    
    % 移除已合并分量
    ws(merge_set) = [];
    ms(:,merge_set) = [];
    Ps(merge_set) = [];
end

% 修剪小权重分量 (阈值0.001)
keep_idx = new_ws > 0.001 * sum(new_ws);
gm_phd.ws = new_ws(keep_idx);
gm_phd.ms = new_ms(:, keep_idx);
gm_phd.Ps = new_Ps(keep_idx);

% 归一化权重
gm_phd.ws = gm_phd.ws / sum(gm_phd.ws);
end