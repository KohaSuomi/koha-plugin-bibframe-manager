import { useBibframeStore } from '../store/index.js';
import { useSearchStore } from '../store/search.js';

export default {
    name: 'SearchRecords',
    setup() {
        const store = useBibframeStore();
        const search = useSearchStore();

        const handleSearch = () => {
            search.searchByBiblionumber();
        };

        const handleConvert = async () => {
            await store.convertRecord(search.currentRecord.biblio_id);
            if (!store.error) search.clearResult();
        }
        
        return {
            store,
            search,
            handleSearch,
            handleConvert
        };
    },
    template: `
    <div class="search-records">
            <!-- Error Alert -->
            <div v-if="search.error" class="alert alert-danger alert-dismissible fade show py-2" role="alert">
                <i class="fas fa-exclamation-triangle"></i> {{ search.error }}
                <button type="button" class="btn-close" @click="search.clearError()"></button>
            </div>
            
            <!-- Success Alert -->
            <div v-if="search.success" class="alert alert-success alert-dismissible fade show py-2" role="alert">
                <i class="fas fa-check-circle"></i> {{ search.success }}
                <button type="button" class="btn-close" @click="search.clearSuccess()"></button>
            </div>
            
            <form @submit.prevent="handleSearch" class="mb-2">
                <div class="input-group">
                    <input 
                        v-model="search.biblionumber" 
                        type="text" 
                        class="form-control" 
                        placeholder="Enter biblionumber..."
                        :disabled="search.loading"
                    />
                    <button type="submit" class="btn btn-primary" :disabled="search.loading">
                        <i class="fas" :class="search.loading ? 'fa-spinner fa-spin' : 'fa-search'"></i>
                        {{ search.loading ? 'Loading...' : 'Load' }}
                    </button>
                </div>
            </form>
            
            <!-- Display loaded record info -->
            <div class="card" v-if="search.currentRecord">
                <div class="card-body py-2">
                    <div class="d-flex justify-content-between align-items-center">
                        <div class="text-truncate me-2">
                            <small>
                                <strong>{{ search.currentRecord.title || 'N/A' }}</strong>
                                <span v-if="search.currentRecord.author" class="text-muted"> — {{ search.currentRecord.author }}</span>
                            </small>
                        </div>
                        <button @click="handleConvert" class="btn btn-sm btn-primary flex-shrink-0">
                            <i class="fas fa-plus"></i> Convert to Bibframe
                        </button>
                    </div>
                </div>
            </div>
    </div>
    `
};