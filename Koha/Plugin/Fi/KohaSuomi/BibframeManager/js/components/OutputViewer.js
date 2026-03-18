// Output Viewer Component
import { useBibframeStore } from '../store/index.js';
import { useFileOperations } from '../composables/utils.js';

export default {
    name: 'OutputViewer',
    setup() {
        const store = useBibframeStore();
        const { downloadOutput, copyToClipboard } = useFileOperations();
        
        const handleDownload = () => {
            downloadOutput(store.generatedOutput, store.recordId, store.outputFormat);
        };
        
        const handleCopy = () => {
            if (copyToClipboard(store.generatedOutput)) {
                store.setSuccess('Copied to clipboard!');
                setTimeout(() => store.clearSuccess(), 2000);
            }
        };
        
        return {
            store,
            handleDownload,
            handleCopy
        };
    },
    template: `
        <div v-if="store.generatedOutput" class="mt-4">
            <h4><i class="fas fa-code"></i> Generated Output</h4>
            <div class="d-flex gap-2 mb-3">
                <button @click="handleCopy" class="btn btn-sm btn-outline-secondary">
                    <i class="fas fa-copy"></i> Copy to Clipboard
                </button>
                <button @click="handleDownload" class="btn btn-sm btn-outline-primary">
                    <i class="fas fa-download"></i> Download
                </button>
            </div>
            <div class="result-box">{{ store.generatedOutput }}</div>
        </div>
    `
};
