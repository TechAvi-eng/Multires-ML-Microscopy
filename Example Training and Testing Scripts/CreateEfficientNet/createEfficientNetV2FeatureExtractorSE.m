function net = createEfficientNetV2FeatureExtractorSE(inputSize)
    % Create EfficientNetV2-style network with GroupNorm that outputs a feature map
    % with 1/16 scale of the input and 1024 channels
    % Now enhanced with Squeeze-and-Excitation (SE) blocks and fixed residual connections

    if nargin < 1
        inputSize = [528 704 1]; % Default input size if none is provided
    end

    lgraph = layerGraph(); % Initialize empty layer graph

    % Initial stem block with stride 2 (reduces spatial resolution by half)
    stemLayers = [
        imageInputLayer(inputSize, 'Name', 'Input_data', 'Normalization', 'none') % Input layer
        convolution2dLayer(3, 64, 'Stride', 2, 'Padding', 'same', 'Name', 'conv1', 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros') % Conv layer with downsampling
        groupNormalizationLayer(calculateNumGroups(64), 'Name', 'stem_gn') % Group normalization
        swishLayer('Name', 'stem_swish') % Swish activation
    ];

    lgraph = addLayers(lgraph, stemLayers); % Add stem block to graph

    % Configuration for each stage: {block type, output channels, number of layers, stride, expansion factor, SE ratio}
    blockConfigs = {
        {'fused', 32,  2, 1, 1, 0.25}
        {'fused', 64,  3, 2, 4, 0.25}
        {'mb',    128, 3, 2, 4, 0.25}
        {'mb',    256, 4, 2, 4, 0.25}
        {'mb',    512, 3, 1, 4, 0.25}
        {'mb',    1024, 1, 1, 2, 0.25}
    };

    prevLayerName = 'stem_swish'; % Track last layer name for connections
    currentChannels = 64; % Track current channel count (starts with stem output)

    % Iterate through stages and add blocks to graph
    for stageIdx = 1:length(blockConfigs)
        config = blockConfigs{stageIdx};
        blockType = config{1};
        outputChannels = config{2};
        numLayers = config{3};
        stride = config{4};
        expansion = config{5};
        seRatio = config{6};

        for blockIdx = 1:numLayers
            currentStride = 1;
            if blockIdx == 1
                currentStride = stride; % Apply stride on first block of each stage
            end

            % Add appropriate block type
            if strcmp(blockType, 'fused')
                [lgraph, prevLayerName] = addFusedMBConvBlock(lgraph, prevLayerName, ...
                    currentChannels, outputChannels, currentStride, expansion, seRatio, ...
                    sprintf('stage%d_block%d', stageIdx, blockIdx));
            else
                [lgraph, prevLayerName] = addMBConvBlock(lgraph, prevLayerName, ...
                    currentChannels, outputChannels, currentStride, expansion, seRatio, ...
                    sprintf('stage%d_block%d', stageIdx, blockIdx));
            end
            
            % Update current channels
            currentChannels = outputChannels;
        end
    end

    % Final normalization and activation
    finalLayers = [
        groupNormalizationLayer(calculateNumGroups(1024), 'Name', 'final_gn')
        swishLayer('Name', 'final_swish')
    ];

    lgraph = addLayers(lgraph, finalLayers); % Add final layers
    lgraph = connectLayers(lgraph, prevLayerName, 'final_gn'); % Connect last block to final layers

    net = dlnetwork(lgraph); % Convert to dlnetwork object
end

function [lgraph, lastLayerName] = addFusedMBConvBlock(lgraph, inputName, inputChannels, outputChannels, stride, expansion, seRatio, blockName)
    % Add Fused-MBConv block with SE and optional projection and residual connection
    expanded = outputChannels * expansion;

    % Main fused convolution layer with Swish activation
    layers = [
        convolution2dLayer(3, expanded, 'Stride', stride, 'Padding', 'same', ...
            'Name', [blockName '_fused_conv'], 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros')
        groupNormalizationLayer(calculateNumGroups(expanded), 'Name', [blockName '_gn1'])
        swishLayer('Name', [blockName '_swish1'])
    ];

    lgraph = addLayers(lgraph, layers); % Add layers to graph
    lgraph = connectLayers(lgraph, inputName, [blockName '_fused_conv']); % Connect input
    
    % Add SE block after activation if seRatio > 0
    if seRatio > 0
        [lgraph, seOutName] = addSqueezeExcitationBlock(lgraph, [blockName '_swish1'], expanded, seRatio, blockName);
        lastLayerAfterSE = seOutName;
    else
        lastLayerAfterSE = [blockName '_swish1'];
    end

    % Optional projection layer (1x1 conv) if expanded doesn't match outputChannels
    if expanded ~= outputChannels
        projLayers = [
            convolution2dLayer(1, outputChannels, 'Stride', 1, 'Padding', 'same', ...
                'Name', [blockName '_project_conv'], 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros')
            groupNormalizationLayer(calculateNumGroups(outputChannels), 'Name', [blockName '_gn2'])
        ];
        
        lgraph = addLayers(lgraph, projLayers);
        lgraph = connectLayers(lgraph, lastLayerAfterSE, [blockName '_project_conv']);
        lastLayerName = [blockName '_gn2']; % Track last layer for connections
    else
        lastLayerName = lastLayerAfterSE;
    end

    % Add residual connection if stride=1 and channel counts match (or add projection if needed)
    if stride == 1
        % Add identity shortcut if channels match
        if inputChannels == outputChannels
            lgraph = addLayers(lgraph, additionLayer(2, 'Name', [blockName '_add']));
            lgraph = connectLayers(lgraph, inputName, [blockName '_add/in1']);
            lgraph = connectLayers(lgraph, lastLayerName, [blockName '_add/in2']);
            lastLayerName = [blockName '_add']; % Update last layer to addition
        elseif inputChannels ~= outputChannels
            % Add projection shortcut if channels don't match
            shortcutLayers = [
                convolution2dLayer(1, outputChannels, 'Stride', 1, 'Padding', 'same', ...
                    'Name', [blockName '_shortcut_conv'], 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros')
                groupNormalizationLayer(calculateNumGroups(outputChannels), 'Name', [blockName '_shortcut_gn'])
            ];
            
            lgraph = addLayers(lgraph, shortcutLayers);
            lgraph = connectLayers(lgraph, inputName, [blockName '_shortcut_conv']);
            
            % Add addition layer to combine main path and shortcut
            lgraph = addLayers(lgraph, additionLayer(2, 'Name', [blockName '_add']));
            lgraph = connectLayers(lgraph, [blockName '_shortcut_gn'], [blockName '_add/in1']);
            lgraph = connectLayers(lgraph, lastLayerName, [blockName '_add/in2']);
            lastLayerName = [blockName '_add']; % Update last layer to addition
        end
    end
end

function [lgraph, lastLayerName] = addMBConvBlock(lgraph, inputName, inputChannels, outputChannels, stride, expansion, seRatio, blockName)
    % Add MBConv block (expand -> depthwise -> SE -> project) with residual

    expanded = inputChannels * expansion;

    % Expand (1x1)
    expandLayers = [
        convolution2dLayer(1, expanded, 'Stride', 1, 'Padding', 'same', ...
            'Name', [blockName '_expand_conv'], 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros')
        groupNormalizationLayer(calculateNumGroups(expanded), 'Name', [blockName '_gn1'])
        swishLayer('Name', [blockName '_swish1'])
    ];
    
    lgraph = addLayers(lgraph, expandLayers);
    lgraph = connectLayers(lgraph, inputName, [blockName '_expand_conv']);
    
    % Depthwise (3x3)
    dwLayers = [
        groupedConvolution2dLayer(3, 1, expanded, 'Stride', stride, 'Padding', 'same', ...
            'Name', [blockName '_depthwise_conv'], 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros')
        groupNormalizationLayer(calculateNumGroups(expanded), 'Name', [blockName '_gn2'])
        swishLayer('Name', [blockName '_swish2'])
    ];
    
    lgraph = addLayers(lgraph, dwLayers);
    lgraph = connectLayers(lgraph, [blockName '_swish1'], [blockName '_depthwise_conv']);
    
    % Add SE block after depthwise conv if seRatio > 0
    if seRatio > 0
        [lgraph, seOutName] = addSqueezeExcitationBlock(lgraph, [blockName '_swish2'], expanded, seRatio, blockName);
        lastLayerAfterSE = seOutName;
    else
        lastLayerAfterSE = [blockName '_swish2'];
    end
    
    % Project (1x1)
    projLayers = [
        convolution2dLayer(1, outputChannels, 'Stride', 1, 'Padding', 'same', ...
            'Name', [blockName '_project_conv'], 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros')
        groupNormalizationLayer(calculateNumGroups(outputChannels), 'Name', [blockName '_gn3'])
    ];
    
    lgraph = addLayers(lgraph, projLayers);
    lgraph = connectLayers(lgraph, lastLayerAfterSE, [blockName '_project_conv']);
    
    lastLayerName = [blockName '_gn3'];

    % Add residual connection if stride=1 and channel counts match (or add projection if needed)
    if stride == 1
        % Add identity shortcut if channels match
        if inputChannels == outputChannels
            lgraph = addLayers(lgraph, additionLayer(2, 'Name', [blockName '_add']));
            lgraph = connectLayers(lgraph, inputName, [blockName '_add/in1']);
            lgraph = connectLayers(lgraph, lastLayerName, [blockName '_add/in2']);
            lastLayerName = [blockName '_add']; % Update last layer to addition
        elseif inputChannels ~= outputChannels
            % Add projection shortcut if channels don't match
            shortcutLayers = [
                convolution2dLayer(1, outputChannels, 'Stride', 1, 'Padding', 'same', ...
                    'Name', [blockName '_shortcut_conv'], 'BiasLearnRateFactor', 0, 'BiasInitializer', 'zeros')
                groupNormalizationLayer(calculateNumGroups(outputChannels), 'Name', [blockName '_shortcut_gn'])
            ];
            
            lgraph = addLayers(lgraph, shortcutLayers);
            lgraph = connectLayers(lgraph, inputName, [blockName '_shortcut_conv']);
            
            % Add addition layer to combine main path and shortcut
            lgraph = addLayers(lgraph, additionLayer(2, 'Name', [blockName '_add']));
            lgraph = connectLayers(lgraph, [blockName '_shortcut_gn'], [blockName '_add/in1']);
            lgraph = connectLayers(lgraph, lastLayerName, [blockName '_add/in2']);
            lastLayerName = [blockName '_add']; % Update last layer to addition
        end
    end
end

function [lgraph, outputName] = addSqueezeExcitationBlock(lgraph, inputName, channels, seRatio, blockName)
    % Add a Squeeze-and-Excitation block
    % seRatio determines the reduction ratio for the bottleneck
    
    % Calculate the number of bottleneck channels
    bottleneckChannels = max(1, floor(channels * seRatio));
    
    % Create a custom SE block using MATLAB's layers with proper reshaping
    % for compatibility with spatial features
    
    % 1. Global Average Pooling to get channel statistics
    poolLayer = globalAveragePooling2dLayer('Name', [blockName '_se_pool']);
    
    % 2. Fully connected layers for channel attention
    fc1 = convolution2dLayer(1, bottleneckChannels, 'Name', [blockName '_se_fc1']);
    swish1 = swishLayer('Name', [blockName '_se_swish']);
    fc2 = convolution2dLayer(1,channels, 'Name', [blockName '_se_fc2']);
    sigmoid1 = sigmoidLayer('Name', [blockName '_se_sigmoid']);
    
    % 3. Custom function layer to reshape and apply weights to input feature map
    seApplyLayer = multiplicationLayer(2, ...
                                'Name', [blockName '_se_apply']);
    
    % Add all layers to graph
    lgraph = addLayers(lgraph, poolLayer);
    lgraph = connectLayers(lgraph, inputName, poolLayer.Name);
    
    lgraph = addLayers(lgraph, fc1);
    lgraph = connectLayers(lgraph, poolLayer.Name, fc1.Name);
    
    lgraph = addLayers(lgraph, swish1);
    lgraph = connectLayers(lgraph, fc1.Name, swish1.Name);
    
    lgraph = addLayers(lgraph, fc2);
    lgraph = connectLayers(lgraph, swish1.Name, fc2.Name);
    
    lgraph = addLayers(lgraph, sigmoid1);
    lgraph = connectLayers(lgraph, fc2.Name, sigmoid1.Name);
    
    lgraph = addLayers(lgraph, seApplyLayer);
    lgraph = connectLayers(lgraph, sigmoid1.Name, [blockName '_se_apply/in1']);
    lgraph = connectLayers(lgraph, inputName, [blockName '_se_apply/in2']);
    
    outputName = [blockName '_se_apply'];
end

function numGroups = calculateNumGroups(numChannels)
    % Calculate suitable number of groups for group normalization
    numGroups = min(floor(numChannels / 32), 32);
    numGroups = max(numGroups, 1);
    while mod(numChannels, numGroups) ~= 0 && numGroups > 1
        numGroups = numGroups - 1;
    end
end