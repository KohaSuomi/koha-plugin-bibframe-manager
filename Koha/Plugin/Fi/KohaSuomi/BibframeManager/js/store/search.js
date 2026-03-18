const { defineStore } = Pinia;
import { useKohaApi } from '../composables/api.js';
import { useBibframeStore } from './index.js';

export const useSearchStore = defineStore('search', {
    state: () => ({
        biblionumber: '',
        currentRecord: null,
        loading: false,
        error: null,
        success: null
    }),
    
    actions: {
        async searchByBiblionumber() {
            if (!this.biblionumber) {
                this.error = 'Please enter a biblionumber';
                return;
            }
            
            this.loading = true;
            this.error = null;
            this.success = null;
            
            try {
                const { getRecordByBiblionumber } = useKohaApi();
                const record = await getRecordByBiblionumber(this.biblionumber);
                
                if (record) {
                    this.currentRecord = record;
                    
                    this.success = `Record ${this.biblionumber} loaded successfully!`;
                } else {
                    this.error = `Record ${this.biblionumber} not found`;
                }
            } catch (err) {
                this.error = err.message || 'Failed to load record';
            } finally {
                this.loading = false;
            }
        },
        
        clearError() {
            this.error = null;
        },
        
        clearSuccess() {
            this.success = null;
        },
        
        reset() {
            this.biblionumber = '';
            this.currentRecord = null;
            this.error = null;
            this.success = null;
        }
    }
});